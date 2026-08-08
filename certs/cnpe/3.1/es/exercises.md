# Ejercicios guiados — Tema 3.1: Configuring Secure Service-to-Service Communication (CNPE)

> **Objetivo del laboratorio:** partir de un cluster donde el tráfico este-oeste (service-to-service) viaja en plano y sin identidad, y llegar a un modelo *zero-trust* en el que cada llamada está **cifrada (mTLS)**, **autenticada por identidad criptográfica (SPIFFE)** y **autorizada explícitamente (L7 authz + NetworkPolicy L3/L4)**.
>
> **Prerrequisitos:** un cluster de test descartable (`kind`/`minikube`, ≥ 4 vCPU / 8 GiB), `kubectl` ≥ 1.29, `istioctl` ≥ 1.22, `helm` ≥ 3.14 y una CNI que aplique `NetworkPolicy` (Calico o Cilium — el CNI por defecto de `kind` **no** las aplica). Trabajaremos en el namespace `secure-demo`.
>
> **Convención:** los bloques `# salida esperada` muestran una salida representativa; los serial numbers, hashes y timestamps variarán en tu entorno.

---

## Ejercicio 0 — Preparar el terreno y establecer la línea de base insegura

El punto de partida obligatorio: demostrar empíricamente que sin mesh ni policies el tráfico es texto plano y cualquier pod puede hablar con cualquier otro.

**Pasos**

1. Creá el cluster con una CNI que aplique NetworkPolicies (Calico sobre `kind`):

   ```bash
   kind create cluster --name cnpe-31 --config - <<'EOF'
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   networking:
     disableDefaultCNI: true
     podSubnet: "10.244.0.0/16"
   EOF
   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
   kubectl -n kube-system rollout status ds/calico-node --timeout=180s
   ```

2. Creá el namespace de trabajo y dos workloads con ServiceAccounts distintas (la identidad es por SA, no por pod):

   ```bash
   kubectl create namespace secure-demo
   kubectl create serviceaccount frontend -n secure-demo
   kubectl create serviceaccount backend  -n secure-demo

   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: backend
     labels: { app: backend }
   spec:
     replicas: 1
     selector: { matchLabels: { app: backend } }
     template:
       metadata: { labels: { app: backend } }
       spec:
         serviceAccountName: backend
         containers:
         - name: httpbin
           image: kennethreitz/httpbin:latest
           ports: [{ containerPort: 80 }]
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: backend
   spec:
     selector: { app: backend }
     ports: [{ port: 8000, targetPort: 80 }]
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: frontend
     labels: { app: frontend }
   spec:
     replicas: 1
     selector: { matchLabels: { app: frontend } }
     template:
       metadata: { labels: { app: frontend } }
       spec:
         serviceAccountName: frontend
         containers:
         - name: curl
           image: curlimages/curl:8.8.0
           command: ["sleep","infinity"]
   EOF
   kubectl -n secure-demo rollout status deploy/backend deploy/frontend
   ```

3. Verificá conectividad L7 (todo se permite hoy):

   ```bash
   kubectl -n secure-demo exec deploy/frontend -- \
     curl -s -o /dev/null -w "HTTP %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # HTTP 200
   ```

4. Probá que un pod **de otro namespace y sin relación con backend** también llega (segmentación inexistente):

   ```bash
   kubectl run intruso --image=curlimages/curl:8.8.0 -n default --restart=Never -- sleep infinity
   kubectl -n default exec intruso -- \
     curl -s -o /dev/null -w "HTTP %{http_code}\n" http://backend.secure-demo:8000/get
   # salida esperada:
   # HTTP 200
   ```

5. Capturá el tráfico en el nodo para confirmar que viaja en claro. Identificá el nodo del pod `backend` y sniffeá el puerto 80:

   ```bash
   NODE=$(kubectl -n secure-demo get pod -l app=backend -o jsonpath='{.items[0].spec.nodeName}')
   docker exec "$NODE" bash -c \
     "tcpdump -A -i any -c 20 'tcp port 80 and host '$(kubectl -n secure-demo get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')" 2>/dev/null | grep -i 'User-Agent\|GET /get'
   # salida esperada (texto plano legible):
   # GET /get HTTP/1.1
   # User-Agent: curl/8.8.0
   ```

> **Preguntas — bloque 0**
> 1. En Kubernetes *vanilla*, ¿qué controla el destino permitido de una conexión pod-a-pod por defecto, y por qué el paso 4 tiene éxito?
> 2. La identidad de cada workload la fijamos con `serviceAccountName`. ¿Por qué el nombre del pod o su IP son inadecuados como identidad de seguridad para autorización?
> 3. ¿Por qué el paso 5 confirma un riesgo real y no solo teórico? Nombrá dos vectores concretos que esta captura habilita.

---

## Ejercicio 1 — Segmentación L3/L4 con NetworkPolicy (default-deny + allow explícito)

Antes de cifrar, cerramos la red: modelo *default-deny* y apertura mínima. NetworkPolicy opera en capa 3/4 (IP/puerto), es aditiva y no entiende identidad de aplicación — esa es su frontera respecto al mesh.

**Pasos**

1. Aplicá un `default-deny` de ingress **y** egress en `secure-demo`:

   ```bash
   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
   spec:
     podSelector: {}
     policyTypes: [Ingress, Egress]
   EOF
   ```

2. Comprobá que ahora *todo* se cae, incluido el tráfico legítimo (frontend→backend). El `--max-time` evita que el curl cuelgue:

   ```bash
   kubectl -n secure-demo exec deploy/frontend -- \
     curl -s -m 5 -o /dev/null -w "HTTP %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # command terminated with exit code 28   (timeout: la conexión se descarta)
   ```

3. Permitidí explícitamente: (a) DNS de salida hacia `kube-system`, (b) egress de `frontend` hacia `backend`, (c) ingress a `backend` desde `frontend`:

   ```bash
   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns-egress
   spec:
     podSelector: {}
     policyTypes: [Egress]
     egress:
     - to:
       - namespaceSelector:
           matchLabels: { kubernetes.io/metadata.name: kube-system }
       ports:
       - { protocol: UDP, port: 53 }
       - { protocol: TCP, port: 53 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: frontend-to-backend-egress
   spec:
     podSelector:
       matchLabels: { app: frontend }
     policyTypes: [Egress]
     egress:
     - to:
       - podSelector:
           matchLabels: { app: backend }
       ports:
       - { protocol: TCP, port: 8000 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: backend-ingress-from-frontend
   spec:
     podSelector:
       matchLabels: { app: backend }
     policyTypes: [Ingress]
     ingress:
     - from:
       - podSelector:
           matchLabels: { app: frontend }
       ports:
       - { protocol: TCP, port: 8000 }
   EOF
   ```

4. Verificá que el tráfico legítimo vuelve y el del intruso queda cortado:

   ```bash
   kubectl -n secure-demo exec deploy/frontend -- \
     curl -s -m 5 -o /dev/null -w "frontend->backend: HTTP %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # frontend->backend: HTTP 200

   kubectl -n default exec intruso -- \
     curl -s -m 5 -o /dev/null -w "intruso->backend: %{http_code}\n" http://backend.secure-demo:8000/get
   # salida esperada:
   # command terminated with exit code 28   (bloqueado por default-deny + ingress selectivo)
   ```

> **Preguntas — bloque 1**
> 1. Tras el paso 1 el tráfico frontend→backend cae aunque no escribimos ninguna regla que lo prohíba explícitamente. Explicá el modelo de evaluación (¿por qué una `NetworkPolicy` que selecciona un pod convierte su postura por defecto?).
> 2. ¿Por qué necesitamos una regla de egress **y** una de ingress para un único flujo frontend→backend? ¿Qué extremo aplica cuál?
> 3. Un atacante compromete el pod `backend` y quiere exfiltrar datos a `evil.example.com:443`. ¿Lo permite la configuración actual? Justificá con la policy concreta.
> 4. `NetworkPolicy` no distingue si la conexión entrante viene realmente del ServiceAccount `frontend` o de otro pod que logró la IP correcta. ¿Qué propiedad de seguridad falta y qué mecanismo la aporta (adelanto del Ejercicio 2)?

---

## Ejercicio 2 — mTLS con service mesh (Istio): identidad SPIFFE y cifrado automático

NetworkPolicy nos dio segmentación por topología; ahora agregamos **identidad criptográfica por workload** y **cifrado en tránsito** sin tocar el código de la aplicación. Istio inyecta un sidecar Envoy que emite y rota un **X.509-SVID SPIFFE** por cada ServiceAccount.

**Pasos**

1. Instalá Istio (perfil demo) y habilitá inyección de sidecar en el namespace:

   ```bash
   istioctl install --set profile=demo -y
   kubectl label namespace secure-demo istio-injection=enabled --overwrite
   kubectl -n secure-demo rollout restart deploy/frontend deploy/backend
   kubectl -n secure-demo rollout status deploy/frontend deploy/backend
   ```

2. Confirmá que cada pod ahora tiene 2 containers (app + `istio-proxy`):

   ```bash
   kubectl -n secure-demo get pods
   # salida esperada:
   # NAME                        READY   STATUS    RESTARTS   AGE
   # backend-6c...               2/2     Running   0          40s
   # frontend-7d...              2/2     Running   0          40s
   ```

3. Inspeccioná el certificado (SVID) que Envoy recibió del control plane. La identidad va en el **SAN URI** en formato SPIFFE:

   ```bash
   POD=$(kubectl -n secure-demo get pod -l app=backend -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$POD.secure-demo" -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
   # salida esperada:
   # X509v3 Subject Alternative Name:
   #     URI:spiffe://cluster.local/ns/secure-demo/sa/backend
   ```

4. Mirá el resumen de certificados y su rotación (fijate el `NOT AFTER` — Istio rota por defecto cada 24 h):

   ```bash
   istioctl proxy-config secret "$POD.secure-demo"
   # salida esperada:
   # RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER    NOT AFTER                NOT BEFORE
   # default           Cert Chain     ACTIVE     true           2ec9f1...        2026-08-08T09:14:03Z     2026-08-07T09:12:03Z
   # ROOTCA            CA             ACTIVE     true           1a77bd...        2036-08-04T18:22:11Z     2026-08-04T18:22:11Z
   ```

5. En este punto Istio corre en modo **PERMISSIVE** por defecto: acepta mTLS *y* texto plano. Verificalo — el intruso sin sidecar todavía puede llegar (asumiendo que aflojaste el ingress de NetworkPolicy o lo probás dentro del mesh). Comprobá qué modo rige el workload:

   ```bash
   istioctl x describe pod "$POD.secure-demo" | grep -A2 "mTLS"
   # salida esperada:
   # Effective PeerAuthentication:
   #    Workload mTLS mode: PERMISSIVE
   ```

> **Preguntas — bloque 2**
> 1. Descifrá el URI `spiffe://cluster.local/ns/secure-demo/sa/backend`: ¿qué representa cada segmento (`cluster.local`, `ns/…`, `sa/…`) y por qué esta identidad es más fuerte que una IP o un token bearer?
> 2. ¿Quién firma el SVID del workload y de dónde saca el pod su clave privada? ¿La clave privada sale alguna vez del nodo?
> 3. ¿Por qué el modo por defecto es PERMISSIVE y no STRICT? ¿Qué operación real de plataforma habilita ese modo intermedio?
> 4. La rotación es cada ~24 h sin reiniciar pods. ¿Qué componente hace el *hot reload* del certificado y por qué esto es imposible de operar a mano con `Secret`s montados como archivos?

---

## Ejercicio 3 — Endurecer a STRICT y verificar que el texto plano queda prohibido

Migramos de "acepta todo" a "solo mTLS" con `PeerAuthentication`, y demostramos que la migración es segura (sin downtime) gracias a PERMISSIVE.

**Pasos**

1. Aplicá `PeerAuthentication` en modo STRICT a nivel namespace:

   ```bash
   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: secure-demo
   spec:
     mtls:
       mode: STRICT
   EOF
   ```

2. Confirmá el cambio de modo efectivo:

   ```bash
   istioctl x describe pod "$POD.secure-demo" | grep "Workload mTLS mode"
   # salida esperada:
   # Workload mTLS mode: STRICT
   ```

3. Tráfico *dentro* del mesh (frontend con sidecar) sigue funcionando — el mTLS es transparente:

   ```bash
   kubectl -n secure-demo exec deploy/frontend -c curl -- \
     curl -s -o /dev/null -w "in-mesh: HTTP %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # in-mesh: HTTP 200
   ```

4. Tráfico en texto plano desde fuera del mesh queda rechazado. Lanzá un cliente sin sidecar dentro del mismo namespace y probá:

   ```bash
   kubectl -n secure-demo run plano --image=curlimages/curl:8.8.0 \
     --annotations sidecar.istio.io/inject=false --restart=Never -- sleep infinity
   kubectl -n secure-demo exec plano -- \
     curl -s -m 5 -o /dev/null -w "plano->backend: %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # plano->backend: 000    (curl exit 56: Recv failure — el server exige TLS, el cliente mandó plano)
   ```

5. Verificá desde el lado del servidor que la conexión efectivamente fue mTLS, inspeccionando las métricas de Envoy del backend:

   ```bash
   kubectl -n secure-demo exec "$POD" -c istio-proxy -- \
     pilot-agent request GET stats | grep 'ssl.handshake\|connection_error'
   # salida esperada (los handshakes TLS suben con cada request in-mesh):
   # listener.0.0.0.0_8000.ssl.handshake: 12
   # listener.0.0.0.0_8000.ssl.connection_error: 0
   ```

> **Preguntas — bloque 3**
> 1. Reconstruí la secuencia de una migración *sin downtime* de plano a STRICT en un cluster productivo con decenas de servicios: ¿en qué orden se despliegan sidecars y `PeerAuthentication`, y qué rol cumple PERMISSIVE en el medio?
> 2. En el paso 4 el error es del lado del cliente (`Recv failure`), no un 403. ¿Por qué? ¿En qué capa falla la conexión y qué te dice eso sobre *dónde* se aplica `PeerAuthentication`?
> 3. `PeerAuthentication` puede definirse a nivel mesh, namespace o workload (via `selector`), e incluso por puerto. Si necesitás que **un solo puerto** de un servicio siga aceptando plano (p. ej. un `/healthz` legacy de un scraper externo) manteniendo el resto STRICT, ¿cómo lo expresás?
> 4. STRICT garantiza cifrado y prueba la identidad del *par*, pero por sí solo un frontend comprometido sigue pudiendo llamar a cualquier backend del mesh. ¿Qué garantía **no** te da `PeerAuthentication` y qué recurso la aporta (Ejercicio 4)?

---

## Ejercicio 4 — Autorización L7 basada en identidad con AuthorizationPolicy

mTLS autentica; ahora **autorizamos**. `AuthorizationPolicy` decide, usando el `principal` SPIFFE del certificado del par, quién puede invocar qué método/ruta. Este es el corazón del zero-trust service-to-service.

**Pasos**

1. Aplicá un `deny-all` L7 en el namespace (una policy `ALLOW` vacía que no matchea nada = negar todo):

   ```bash
   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-all
     namespace: secure-demo
   spec:
     {}
   EOF
   ```

2. Confirmá que ahora incluso frontend→backend recibe 403 a nivel aplicación (¡ojo: ahora sí es un 403, no un reset!):

   ```bash
   kubectl -n secure-demo exec deploy/frontend -c curl -- \
     curl -s -w "\n%{http_code}\n" http://backend:8000/get
   # salida esperada:
   # RBAC: access denied
   # 403
   ```

3. Autorizá explícitamente solo al `principal` del frontend, y solo para `GET`:

   ```bash
   kubectl -n secure-demo apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: backend-allow-frontend-get
     namespace: secure-demo
   spec:
     selector:
       matchLabels: { app: backend }
     action: ALLOW
     rules:
     - from:
       - source:
           principals: ["cluster.local/ns/secure-demo/sa/frontend"]
       to:
       - operation:
           methods: ["GET"]
   EOF
   ```

4. Verificá el matrix de acceso: `GET` del frontend pasa, `DELETE` del frontend se niega:

   ```bash
   kubectl -n secure-demo exec deploy/frontend -c curl -- \
     curl -s -o /dev/null -w "GET  -> %{http_code}\n" http://backend:8000/get
   kubectl -n secure-demo exec deploy/frontend -c curl -- \
     curl -s -o /dev/null -w "DELETE -> %{http_code}\n" -X DELETE http://backend:8000/delete
   # salida esperada:
   # GET  -> 200
   # DELETE -> 403
   ```

5. Probá suplantación: creá un tercer workload con SA `attacker` y su propio sidecar; su `principal` es distinto, así que aunque tenga mTLS válido, es rechazado:

   ```bash
   kubectl create sa attacker -n secure-demo
   kubectl -n secure-demo run attacker --image=curlimages/curl:8.8.0 \
     --overrides='{"spec":{"serviceAccountName":"attacker"}}' --restart=Never -- sleep infinity
   kubectl -n secure-demo exec attacker -c attacker -- \
     curl -s -o /dev/null -w "attacker GET -> %{http_code}\n" http://backend:8000/get
   # salida esperada:
   # attacker GET -> 403   (identidad válida pero no autorizada)
   ```

6. Depurá una decisión: activá los logs RBAC de Envoy en el backend y observá la evaluación:

   ```bash
   istioctl proxy-config log "$POD.secure-demo" --level rbac:debug
   kubectl -n secure-demo logs "$POD" -c istio-proxy | grep -i "enforced denied\|enforced allowed" | tail -2
   # salida esperada:
   # ...[rbac] enforced allowed, matched policy ns[secure-demo]-policy[backend-allow-frontend-get]-rule[0]
   # ...[rbac] enforced denied, matched policy none
   ```

> **Preguntas — bloque 4**
> 1. En el paso 2, negar todo se logra con `spec: {}` (una policy `ALLOW` sin reglas). Explicá la lógica de evaluación de Istio: precedencia de `DENY` sobre `ALLOW`, qué pasa cuando **no hay** ninguna `AuthorizationPolicy` que aplique a un workload, y qué cambia en cuanto **existe** al menos una `ALLOW`.
> 2. En el paso 5 el atacante tiene un certificado mTLS perfectamente válido y firmado por la misma CA. ¿Por qué es rechazado? Distinguí *authentication* de *authorization* con este ejemplo concreto.
> 3. El `principal` se escribe `cluster.local/ns/secure-demo/sa/frontend` (sin el prefijo `spiffe://`). ¿De dónde sale ese valor y qué campo del certificado debe presentar el cliente para que matchee? ¿Qué diferencia hay entre `source.principals` y `source.namespaces`?
> 4. Un `principal` depende de que mTLS esté activo. ¿Qué pasa con una `AuthorizationPolicy` basada en `principals` si el `PeerAuthentication` estuviera en PERMISSIVE y llega una conexión en texto plano? ¿Por qué STRICT es prerrequisito para confiar en la authz por identidad?

---

## Ejercicio 5 — Identidad de workload con SPIFFE/SPIRE (más allá del mesh)

Istio trae su propia CA (Citadel/istiod), pero la primitiva subyacente es **SPIFFE**. En plataformas heterogéneas (VMs, multi-cluster, workloads fuera del mesh) se usa **SPIRE** como emisor de identidad. Acá emitís un SVID a mano y ves el ciclo de attestation.

**Pasos**

1. Instalá SPIRE (server + agent) vía Helm en el namespace `spire`:

   ```bash
   helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ && helm repo update
   helm upgrade --install -n spire --create-namespace spire-crds spiffe/spire-crds
   helm upgrade --install -n spire spire spiffe/spire \
     --set global.spire.trustDomain=example.org --wait
   kubectl -n spire get pods
   # salida esperada:
   # spire-server-0            2/2   Running
   # spire-agent-xxxxx         1/1   Running   (uno por nodo, DaemonSet)
   ```

2. Registrá una entry: mapeá **selectors** (atributos del nodo/pod que el agent puede *attestar*) a un SPIFFE ID. El `parentID` es la identidad del agent que attesta:

   ```bash
   AGENT_ID=$(kubectl -n spire exec spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server agent list -output json | jq -r '.agents[0].id')

   kubectl -n spire exec spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server entry create \
       -spiffeID spiffe://example.org/ns/secure-demo/sa/backend \
       -parentID "$AGENT_ID" \
       -selector k8s:ns:secure-demo \
       -selector k8s:sa:backend
   # salida esperada:
   # Entry ID         : 9b2c...-...
   # SPIFFE ID        : spiffe://example.org/ns/secure-demo/sa/backend
   # Parent ID        : spiffe://example.org/spire/agent/k8s_psat/...
   # Selector         : k8s:ns:secure-demo
   # Selector         : k8s:sa:backend
   ```

3. Verificá que el server resolvió la entry y su cadena de confianza:

   ```bash
   kubectl -n spire exec spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server entry show -selector k8s:sa:backend
   # salida esperada:
   # Found 1 entry
   # Entry ID      : 9b2c...
   # SPIFFE ID     : spiffe://example.org/ns/secure-demo/sa/backend
   # X509-SVID TTL : 3600
   ```

4. Observá el TTL corto (default 1 h) y contrastalo con el modelo tradicional de certificados de larga vida.

> **Preguntas — bloque 5**
> 1. Explicá las tres fases del ciclo SPIFFE en SPIRE: **node attestation** (el agent prueba en qué nodo corre), **workload attestation** (el agent identifica al proceso que pide un SVID vía el Workload API socket), y **SVID issuance**. ¿Qué evita que un pod pida el SVID de otro?
> 2. Los selectors `k8s:ns:secure-demo` + `k8s:sa:backend` los verifica el **agent**, no el workload que pide el cert. ¿Por qué es crucial que la attestation la haga un componente confiable del nodo y no la aplicación?
> 3. El SVID no viaja por un `Secret` ni por un archivo montado: el workload lo pide en runtime al **Workload API** (`/run/spire/sockets/agent.sock`). ¿Qué dos problemas de seguridad de los `Secret`s montados resuelve este modelo?
> 4. ¿Qué es el **trust domain** (`example.org`) y por qué la federación entre dos trust domains (p. ej. dos clusters de equipos distintos) requiere intercambiar *bundles* y no compartir la CA raíz?

---

## Ejercicio 6 — Gestión de PKI y trust anchor con cert-manager (rotación del root)

Toda esta cadena depende de una CA. En producción no querés la CA autogenerada de istiod: querés un root gestionado, rotable y auditable. `cert-manager` es la pieza estándar para emitir y rotar la CA intermedia que istiod usa como *plugged-in CA*.

**Pasos**

1. Instalá cert-manager:

   ```bash
   helm repo add jetstack https://charts.jetstack.io && helm repo update
   helm upgrade --install cert-manager jetstack/cert-manager \
     -n cert-manager --create-namespace --set crds.enabled=true --wait
   ```

2. Creá un root self-signed y una CA intermedia (el patrón que reemplaza la CA de istiod):

   ```bash
   kubectl -n cert-manager apply -f - <<'EOF'
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata: { name: selfsigned-root }
   spec: { selfSigned: {} }
   ---
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata: { name: root-ca }
   spec:
     isCA: true
     commonName: cnpe-root
     secretName: root-ca-secret
     duration: 87600h      # 10 años
     privateKey: { algorithm: ECDSA, size: 256 }
     issuerRef: { name: selfsigned-root, kind: Issuer }
   ---
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata: { name: root-ca-issuer }
   spec:
     ca: { secretName: root-ca-secret }
   ---
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata: { name: istio-ca }
   spec:
     isCA: true
     commonName: istio-ca
     secretName: istio-ca-secret
     duration: 8760h       # 1 año — rotable
     renewBefore: 720h     # renueva 30 días antes
     issuerRef: { name: root-ca-issuer, kind: Issuer }
   EOF
   ```

3. Verificá la emisión y la relación de confianza:

   ```bash
   kubectl -n cert-manager get certificate
   # salida esperada:
   # NAME       READY   SECRET             AGE
   # root-ca    True    root-ca-secret     20s
   # istio-ca   True    istio-ca-secret    18s

   kubectl -n cert-manager get secret istio-ca-secret -o jsonpath='{.data.tls\.crt}' \
     | base64 -d | openssl x509 -noout -subject -issuer
   # salida esperada:
   # subject=CN=istio-ca
   # issuer=CN=cnpe-root
   ```

4. Forzá una rotación anticipada de la CA intermedia y observá que cert-manager reemite sin intervención manual:

   ```bash
   kubectl cert-manager renew istio-ca -n cert-manager   # requiere el plugin kubectl-cert_manager
   kubectl -n cert-manager wait --for=condition=Ready certificate/istio-ca --timeout=60s
   kubectl -n cert-manager describe certificate istio-ca | grep -A3 "Events"
   # salida esperada:
   # Events:
   #   Type    Reason     Message
   #   Normal  Issuing    Renewing certificate as requested
   #   Normal  Issued     Certificate issued successfully
   ```

> **Preguntas — bloque 6**
> 1. ¿Por qué separar un **root de larga vida** (10 años, offline idealmente) de una **CA intermedia de vida corta** (1 año, rotable)? ¿Qué gana la plataforma en un incidente de compromiso de clave respecto a usar el root directamente para firmar SVIDs?
> 2. `renewBefore: 720h` sobre `duration: 8760h`. Explicá la ventana de renovación y qué pasaría operacionalmente si `renewBefore` fuera mayor o igual a `duration`.
> 3. Al enchufar esta CA a istiod (montando `istio-ca-secret` como `cacerts` en el namespace `istio-system`), los SVIDs de workload pasan a encadenar a `cnpe-root`. Describí el efecto de rotar la **intermedia** sobre los certificados de workload ya emitidos: ¿siguen siendo válidos? ¿qué componente propaga el nuevo trust bundle?
> 4. Conectá las tres capas del laboratorio: NetworkPolicy (Ej. 1), mTLS/authz (Ej. 2–4) y PKI (Ej. 5–6). Para un flujo frontend→backend, ¿qué garantía aporta *cada* capa y por qué ninguna sustituye a las otras (defense in depth)?

---

## Limpieza

```bash
kind delete cluster --name cnpe-31
```

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Bloque 0

1. **Nada lo restringe por defecto.** El modelo de red de Kubernetes exige conectividad *all-to-all* entre pods sin NAT; sin objetos `NetworkPolicy` (y una CNI que los aplique), todo pod puede alcanzar a cualquier otro en cualquier puerto. Por eso el paso 4 tiene éxito: no existe ninguna barrera L3/L4. La postura por defecto es *allow-all*, exactamente lo contrario de zero-trust.

2. IP y nombre de pod son **efímeros y no verificables**: los pods se reprograman y reciben IPs nuevas constantemente, y un atacante que gana la IP correcta (o hace ARP/route spoofing en la red del nodo) hereda la "identidad". No hay ninguna prueba criptográfica de quién está del otro lado. El `ServiceAccount` es un ancla estable de identidad que luego se materializa como un certificado SPIFFE firmado — algo que no se puede suplantar sin la clave privada.

3. Confirma riesgo real porque la captura muestra **payload legible en el nodo**: cualquiera con acceso al host, a un sidecar comprometido, a un span port del switch o a un CNI mal configurado ve credenciales, tokens `Authorization: Bearer`, PII y bodies completos. Dos vectores concretos: (a) **sniffing pasivo** de secretos en tránsito (robo de tokens/credenciales reusables); (b) **man-in-the-middle activo** — sin autenticación mutua, un atacante puede insertarse y modificar requests/responses (inyección de comandos, redirección de fondos, etc.).

### Bloque 1

1. NetworkPolicy es **aditiva y "default-deny al ser seleccionado"**: mientras ningún policy seleccione a un pod, todo su tráfico está permitido; en cuanto *al menos un* policy con un `policyType` dado (Ingress/Egress) selecciona a ese pod, ese tipo de tráfico pasa a **denegado por defecto** y solo se permite lo que las reglas `allow` habiliten explícitamente. `default-deny-all` usa `podSelector: {}` (selecciona *todos* los pods) con ambos `policyTypes` y **sin** reglas → todo ingress y egress queda prohibido. No hay reglas "deny": el default se invierte por el solo hecho de existir la selección.

2. Porque NetworkPolicy se evalúa en **ambos extremos**: el pod que inicia la conexión está sujeto a sus reglas de **Egress** (¿puede salir hacia ese destino/puerto?) y el pod destino a sus reglas de **Ingress** (¿acepta desde ese origen/puerto?). Con `default-deny` de egress e ingress activos, un flujo necesita que el **origen** tenga permiso de egress *y* el **destino** permiso de ingress; si falta cualquiera, se corta.

3. **No lo permite.** El único egress abierto para el pod `backend` es… ninguno específico: solo escribimos `allow-dns-egress` (que aplica a *todos* los pods por `podSelector: {}`, permitiendo DNS a kube-system) y `frontend-to-backend-egress` (que selecciona solo `app: frontend`). `backend` no tiene ninguna regla de egress hacia `evil.example.com:443`, y como quedó bajo `default-deny-all` (Egress), su salida a Internet está bloqueada — salvo DNS al puerto 53 de kube-system. La exfiltración por 443 falla. (Matiz: podría intentar tunelizar por DNS; por eso el egress DNS también se restringe a kube-system y se monitorea.)

4. Falta **autenticidad de la identidad del origen (authentication) y cifrado**. NetworkPolicy autoriza por *topología* (etiquetas/IP), no verifica criptográficamente que quien conecta *es* el ServiceAccount `frontend`; un pod comprometido que consiga la etiqueta/IP correcta pasa. Lo aporta **mTLS con identidad SPIFFE** (Ejercicio 2): cada extremo presenta un certificado firmado que prueba su ServiceAccount, y la conexión va cifrada.

### Bloque 2

1. `spiffe://cluster.local/ns/secure-demo/sa/backend`: `cluster.local` es el **trust domain** (la raíz de confianza / dominio de emisión); `ns/secure-demo` el namespace; `sa/backend` el ServiceAccount. Es más fuerte que una IP o un token bearer porque (a) está **ligada criptográficamente a una clave privada** que solo ese workload posee — no se puede presentar sin ella; (b) es **verificable por el par** contra la CA en cada handshake, no reusable por interceptación como un bearer token; (c) es **estable** respecto a reprogramaciones de pod e IPs cambiantes.

2. Lo firma la **CA de istiod** (control plane; por defecto una CA autogenerada, reemplazable — Ej. 6). El flujo: el `istio-agent` dentro del pod **genera la clave privada localmente**, arma un CSR, se autentica ante istiod con el JWT del ServiceAccount del pod, e istiod devuelve el certificado firmado. La **clave privada nunca sale del pod/nodo** ni transita la red — solo viaja el CSR y el cert firmado (SDS la entrega a Envoy en memoria).

3. PERMISSIVE existe para **migración incremental sin downtime**: en un cluster con muchos servicios no podés sidecar-izar todo atómicamente. PERMISSIVE deja que un servicio ya con sidecar siga aceptando llamadas en plano de clientes aún no migrados, mientras usa mTLS con los que sí. Permite avanzar servicio por servicio; recién cuando *todos* los clientes hablan mTLS se pasa a STRICT.

4. El **`istio-agent` (SDS — Secret Discovery Service)** hace *hot reload* del certificado en Envoy sin reiniciar el pod: entrega el nuevo cert por gRPC en memoria y Envoy lo adopta en caliente. A mano con `Secret`s montados como archivos es inviable porque (a) los certs de vida corta (~24 h) exigirían miles de rotaciones/día, (b) montar un `Secret` actualizado no garantiza recarga sin reiniciar el proceso, y (c) manejar claves privadas en `Secret`s de etcd amplía enormemente la superficie de exposición.

### Bloque 3

1. Secuencia sin downtime: **(1)** desplegar los sidecars en todos los workloads (inyección) manteniendo `PeerAuthentication` en **PERMISSIVE** (o sin policy, que equivale a permissive) — ahora los servicios *pueden* hablar mTLS pero siguen aceptando plano; **(2)** dejar que el mesh empiece a usar mTLS entre workloads sidecar-izados (transparente); **(3)** verificar con métricas/telemetría que ya no queda tráfico en plano hacia esos servicios; **(4)** recién entonces aplicar **STRICT**. PERMISSIVE es el "puente": evita cortar a los clientes que todavía no tienen sidecar durante la transición.

2. Porque `PeerAuthentication` se aplica en la **capa de transporte (TLS handshake)**, *antes* de que exista una request HTTP que devolver. El cliente en plano manda bytes HTTP; Envoy del server, en STRICT, espera un `ClientHello` TLS, no lo recibe y **cierra la conexión** → el cliente ve `Recv failure` (curl 56), no un 403. Un 403 sería una decisión de *autorización* L7 (Ej. 4), que ocurre *después* de establecer mTLS. La capa donde falla te dice que mTLS es una compuerta previa a cualquier lógica de aplicación.

3. Con una `PeerAuthentication` **por workload y por puerto**: seleccionás el workload y sobreescribís el modo del puerto puntual.
   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata: { name: legacy-health, namespace: secure-demo }
   spec:
     selector: { matchLabels: { app: backend } }
     mtls: { mode: STRICT }
     portLevelMtls:
       9000: { mode: PERMISSIVE }   # puerto (containerPort) del /healthz legacy
   ```
   La clave de `portLevelMtls` es el **puerto del contenedor (targetPort)**, y solo aplica si ese puerto está declarado en el `Service`.

4. No te da **autorización**: STRICT prueba *que el par es quien dice ser y que la conexión va cifrada*, pero no *si ese par tiene permitido llamar a este servicio/método*. Un frontend comprometido con identidad válida sigue autenticándose bien. Eso lo restringe **`AuthorizationPolicy`** (Ej. 4), que decide por `principal` + operación.

### Bloque 4

1. Precedencia de Istio: **DENY se evalúa primero** — si algún policy `DENY` matchea, se rechaza sin más. Si ninguno deniega, se revisan las `ALLOW`: **si no hay ninguna `ALLOW` que aplique al workload, se permite** (default allow, siempre que mTLS/PeerAuth no lo hayan cortado antes). Pero **en cuanto existe al menos una `ALLOW` que selecciona al workload, la postura se invierte a default-deny**: solo pasa lo que alguna regla `ALLOW` habilite explícitamente. Por eso `spec: {}` (una `ALLOW` que no matchea ninguna request) equivale a **negar todo**: existe una ALLOW → default-deny, y ninguna request satisface sus (inexistentes) reglas.

2. El atacante **se autentica** correctamente (cert válido, firmado por la CA, mTLS OK) pero **no se autoriza**: su `principal` es `cluster.local/ns/secure-demo/sa/attacker`, que no figura en `source.principals` de la policy. *Authentication* = "¿quién sos y podés probarlo?" (mTLS lo resuelve). *Authorization* = "¿tenés permiso para hacer esto?" (`AuthorizationPolicy` lo resuelve). Tener una identidad válida no implica tener permisos — exactamente el principio de menor privilegio.

3. El `principal` es el **SPIFFE ID sin el esquema `spiffe://`**, derivado del **SAN URI del certificado del cliente** presentado en el mTLS. Para que matchee, el cliente debe presentar un cert cuyo SAN sea `spiffe://cluster.local/ns/secure-demo/sa/frontend`. Diferencia: `source.principals` matchea la **identidad exacta del ServiceAccount** (más granular y fuerte); `source.namespaces` matchea **cualquier identidad de un namespace** (más amplio, útil para reglas de bloque pero menos preciso).

4. Si `PeerAuthentication` está en PERMISSIVE y entra una conexión en **texto plano**, **no hay certificado ⇒ no hay `principal`**, y una regla basada en `source.principals` **no matchea** (el campo de identidad viene vacío) → la request cae en default-deny (si hay ALLOW) o queda sin identidad verificable. Por eso **STRICT es prerrequisito para confiar en authz por identidad**: solo garantizando que *toda* conexión trae un cert válido podés basar decisiones en el `principal`; en PERMISSIVE, un atacante podría intentar evadir la regla llamando en plano.

### Bloque 5

1. **Node attestation:** al arrancar, el agent prueba en qué nodo corre mediante un plugin (p. ej. `k8s_psat`: presenta un ProjectedServiceAccountToken que el server valida contra la API de Kubernetes) y obtiene su propio SVID de agent. **Workload attestation:** cuando un proceso pide un SVID por el Workload API socket, el agent inspecciona atributos verificables del proceso llamante (namespace, ServiceAccount, UID, labels — vía el kubelet/kernel) sin confiar en lo que el proceso *dice* de sí mismo. **SVID issuance:** el server, matcheando los selectors attestados contra las entries registradas, emite el SVID correspondiente. Un pod no puede pedir el SVID de otro porque sus selectors attestados (ns/sa reales) no matchearán la entry ajena.

2. Porque la seguridad del modelo descansa en que la identidad se **deriva de atributos que el workload no controla ni puede falsificar**. Si la aplicación se auto-declarara `ns:secure-demo, sa:backend`, cualquier proceso mentiría y obtendría cualquier identidad. El agent es un componente confiable del nodo que observa la verdad del sistema (qué pod/SA hizo la llamada por ese socket) — la attestation es la raíz de confianza; delegarla al workload rompería todo.

3. Resuelve: **(a)** la clave privada y el SVID **nunca se persisten en etcd** ni en un `Secret` (que es base64, legible por cualquiera con RBAC de lectura sobre Secrets y respaldado en backups); se entregan efímeros en memoria por el socket. **(b)** Elimina la **rotación manual/estática**: el SVID es de vida corta (1 h) y el workload lo renueva continuamente por el Workload API sin reinicios ni re-montar Secrets, reduciendo la ventana de un cert comprometido.

4. El **trust domain** es el límite administrativo de confianza — la raíz criptográfica bajo la que se emiten y validan todos los SVIDs de ese dominio (`example.org`). Dos trust domains distintos tienen **CAs raíz distintas** y por diseño no confían entre sí. La **federación** intercambia solo los **trust bundles** (los certificados públicos de la CA de cada dominio), de modo que el dominio A puede *validar* SVIDs emitidos por B **sin** compartir claves privadas ni una CA común: cada dominio mantiene autonomía y control de su propia raíz, y se revoca la confianza simplemente dejando de aceptar el bundle del otro.

### Bloque 6

1. Un **root de larga vida y offline** minimiza su exposición (idealmente su clave nunca toca un sistema conectado); firma únicamente CAs intermedias. Las **intermedias de vida corta y rotables** hacen el trabajo diario de firmar SVIDs. Ante compromiso de una intermedia, **revocás/rotás solo la intermedia** y reemitís, sin tocar el root ni redistribuir el trust anchor a todos los clientes — un evento acotado. Si firmaras SVIDs directamente con el root, comprometerlo obligaría a **reemplazar la raíz de confianza en todo el ecosistema**, un evento catastrófico.

2. `renewBefore: 720h` significa que cert-manager **reemite la intermedia 30 días antes** de su expiración (a los 8040 h de vida sobre 8760 h de `duration`), dando margen para propagar el nuevo cert antes de que el viejo caduque. Si `renewBefore ≥ duration`, cert-manager entraría en **renovación permanente/inmediata** (intentaría renovar apenas emite, o rechazaría la config) — nunca habría una ventana de "certificado estable", provocando reemisiones constantes y posible thrash.

3. Los SVIDs de workload **ya emitidos siguen siendo válidos** hasta su propia expiración/rotación, porque encadenan al **root (`cnpe-root`)**, no a la intermedia puntual — y el root no cambió. Al rotar la intermedia, **istiod adopta la nueva** para firmar SVIDs futuros y **distribuye el trust bundle actualizado** (que incluye la vieja y la nueva intermedia durante el solape) vía SDS a todos los Envoy, de modo que la validación no se rompe durante la transición. La superposición de intermedias en el bundle es lo que permite rotar sin caídas.

4. Defense in depth, capa por capa para frontend→backend:
   - **NetworkPolicy (L3/L4):** limita *qué pods pueden siquiera intentar una conexión TCP* al puerto del backend. Reduce superficie de ataque y contiene movimiento lateral aunque el mesh falle o un pod no tenga sidecar. No entiende identidad de app.
   - **mTLS / PeerAuthentication (transporte):** garantiza **confidencialidad e integridad** (nadie sniffea ni MITM) y **autenticación mutua** por identidad SPIFFE. No decide *permisos*.
   - **AuthorizationPolicy (L7):** decide *quién puede hacer qué* (principal + método/ruta) — least privilege. Depende de que mTLS provea un `principal` confiable.
   - **PKI / SPIFFE-SPIRE / cert-manager (identidad y confianza):** es el cimiento que hace verificables las identidades y rotables/revocables las CAs; sin una PKI sana, el `principal` en el que confían las capas superiores no vale nada.

   Ninguna sustituye a otra: NetworkPolicy no cifra ni autentica identidad de app; mTLS no autoriza; AuthorizationPolicy no contiene tráfico de pods sin sidecar ni protege a nivel red; y todas colapsan si la PKI está comprometida. Juntas, un atacante debe vencer red **y** transporte **y** authz **y** PKI.

</details>

---

### Fuentes oficiales

- Istio — *Security concepts* (identidad, PKI, mTLS, authz): https://istio.io/latest/docs/concepts/security/
- Istio — `PeerAuthentication` reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — `AuthorizationPolicy` reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — *Mutual TLS migration*: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Plug in CA certificates* (cert-manager / cacerts): https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- SPIFFE — *Overview* y *X.509-SVID*: https://spiffe.io/docs/latest/spiffe-about/overview/
- SPIRE — *Concepts* (attestation, Workload API, federation): https://spiffe.io/docs/latest/spire-about/spire-concepts/
- cert-manager — *Documentation* (Issuer, Certificate, renewal): https://cert-manager.io/docs/
- CNCF — *CNPE Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf