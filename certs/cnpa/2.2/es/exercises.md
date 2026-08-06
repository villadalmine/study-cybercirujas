# Tema 2.2 — Secure Service-to-Service Communication

## Ejercicios guiados

> **Rol del contenido:** estos labs se ejecutan de punta a punta sobre un cluster desechable. La secuencia está pensada para que veas *por qué* el tráfico este-oeste inseguro es el problema por defecto en Kubernetes, y luego construyas, capa por capa, la postura de **zero-trust**: segmentación L3/L4, **mTLS** automático, autorización L7 por identidad de workload y, finalmente, la raíz de confianza (**SPIFFE/SPIRE**, `cert-manager`).
>
> Como Platform Engineer tu entregable no es "un servicio con TLS", sino **una capability de plataforma**: un golden path donde el mTLS y las políticas son un default que el equipo de aplicación hereda sin escribir criptografía. Los ejercicios están escritos con esa lente.

### Requisitos previos

- `kubectl` ≥ 1.29, `helm` ≥ 3.14, `kind` ≥ 0.23, `istioctl` ≥ 1.24, la CLI `cilium`, `jq`, `openssl` y `step` (opcional).
- ~6 GB de RAM libres para el cluster `kind`.
- Todo lo que se crea vive en el cluster `sec-mesh`; al terminar se borra con `kind delete cluster --name sec-mesh`.

Verificá herramientas antes de empezar:

```bash
kubectl version --client -o yaml | grep gitVersion
istioctl version --remote=false
cilium version --client
```

---

## Ejercicio 1 — El punto de partida: tráfico en claro y sin identidad

**Objetivo:** demostrar empíricamente que dos Pods se hablan en texto plano y que Kubernetes, por defecto, no aporta ni cifrado ni identidad verificable entre servicios.

1. Creá un cluster `kind` **sin CNI por defecto** (vamos a instalar Cilium para tener NetworkPolicy real en el Ejercicio 2). Guardá esto como `kind-sec.yaml`:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: sec-mesh
   networking:
     disableDefaultCNI: true          # desactivamos kindnet
     kubeProxyMode: none              # Cilium reemplaza kube-proxy
   nodes:
     - role: control-plane
     - role: worker
   ```

   ```bash
   kind create cluster --config kind-sec.yaml
   ```

2. Instalá Cilium como CNI (lo necesitamos ya para que los nodos pasen a `Ready`):

   ```bash
   cilium install --version 1.16.3 \
     --set kubeProxyReplacement=true
   cilium status --wait
   ```

   Salida esperada (recortada):

   ```
       /¯¯\
    /¯¯\__/¯¯\    Cilium:             OK
    \__/¯¯\__/    Operator:           OK
    /¯¯\__/¯¯\    Hubble Relay:       disabled
    \__/¯¯\__/    ClusterMesh:        disabled
       \__/

   DaemonSet   cilium   Desired: 2, Ready: 2/2, Available: 2/2
   ```

3. Creá el namespace de la demo y desplegá dos workloads con **ServiceAccounts distintas** (la identidad de un workload en Kubernetes es su ServiceAccount — retenelo, es la base de todo el ejercicio):

   ```yaml
   # apps.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: secure-demo
   ---
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: httpbin
     namespace: secure-demo
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: httpbin
     namespace: secure-demo
     labels: { app: httpbin }
   spec:
     replicas: 1
     selector:
       matchLabels: { app: httpbin }
     template:
       metadata:
         labels: { app: httpbin }
       spec:
         serviceAccountName: httpbin
         containers:
           - name: httpbin
             image: kennethreitz/httpbin
             ports:
               - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: httpbin
     namespace: secure-demo
   spec:
     selector: { app: httpbin }
     ports:
       - name: http               # el nombre del puerto importa (ver E3)
         port: 8000
         targetPort: 80
   ---
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: sleep
     namespace: secure-demo
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: sleep
     namespace: secure-demo
     labels: { app: sleep }
   spec:
     replicas: 1
     selector:
       matchLabels: { app: sleep }
     template:
       metadata:
         labels: { app: sleep }
       spec:
         serviceAccountName: sleep
         containers:
           - name: sleep
             image: curlimages/curl
             command: ["/bin/sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f apps.yaml
   kubectl -n secure-demo wait --for=condition=Ready pod --all --timeout=120s
   ```

4. Confirmá que hay conectividad L3 libre — `sleep` llega a `httpbin` sin ninguna restricción:

   ```bash
   kubectl -n secure-demo exec deploy/sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get
   ```

   Salida esperada:

   ```
   200
   ```

5. **Probá que el tráfico va en claro.** Levantá un contenedor efímero con herramientas de red pegado al Pod `httpbin` y capturá el tráfico mientras generás una request desde `sleep`:

   ```bash
   # Terminal A: sniffer sobre el network namespace de httpbin
   HTTPBIN=$(kubectl -n secure-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   kubectl -n secure-demo debug -it $HTTPBIN --image=nicolaka/netshoot \
     --target=httpbin -- tcpdump -A -s0 -i eth0 'tcp port 80 and greater 100'
   ```

   ```bash
   # Terminal B: generá tráfico con un payload reconocible
   kubectl -n secure-demo exec deploy/sleep -- \
     curl -s -H 'X-Secret: PLATAFORMA-1234' http://httpbin:8000/get >/dev/null
   ```

   En la Terminal A vas a ver el header en texto plano dentro del paquete:

   ```
   GET /get HTTP/1.1
   Host: httpbin:8000
   X-Secret: PLATAFORMA-1234
   ```

**Preguntas de verificación (E1)**

- **E1-P1.** ¿Qué dos garantías de seguridad NO provee Kubernetes por defecto para el tráfico este-oeste, y cuál demostraste en el paso 5?
- **E1-P2.** El `Service` `httpbin` no aplica ninguna restricción de origen. Si un Pod comprometido en otro namespace resuelve `httpbin.secure-demo.svc.cluster.local`, ¿qué se lo impide llegar? ¿Por qué esto viola el principio de **least privilege**?
- **E1-P3.** ¿Por qué usar una ServiceAccount distinta por workload (en vez de la `default`) es un prerequisito, y no un detalle cosmético, para todo lo que sigue?

---

## Ejercicio 2 — Segmentación L3/L4: `NetworkPolicy` con default-deny

**Objetivo:** aplicar el primer control de zero-trust: nadie habla con nadie salvo que exista una regla explícita. Esto es defensa en profundidad *por debajo* del mesh — opera aunque el mesh falle o no esté inyectado.

1. Aplicá un **default-deny de ingress y egress** en `secure-demo`. Un `podSelector: {}` selecciona *todos* los Pods del namespace:

   ```yaml
   # default-deny.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: secure-demo
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
       - Egress
   ```

   ```bash
   kubectl apply -f default-deny.yaml
   ```

2. Verificá que ahora la comunicación está cortada (y también el DNS, deliberadamente):

   ```bash
   kubectl -n secure-demo exec deploy/sleep -- \
     curl -s --max-time 5 http://httpbin:8000/get -o /dev/null -w "%{http_code}\n" || echo "BLOCKED"
   ```

   Salida esperada:

   ```
   curl: (28) Resolving timed out after 5000 milliseconds
   BLOCKED
   ```

3. Escribí una política de **least privilege** que permita exactamente el flujo `sleep → httpbin:80` y el DNS hacia `kube-system`. Fijate que hay que abrir **egress en el cliente** *y* **ingress en el servidor**, y que el DNS necesita su propia regla (puerto 53 UDP/TCP):

   ```yaml
   # allow-sleep-to-httpbin.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: secure-demo
   spec:
     podSelector: {}
     policyTypes: [Egress]
     egress:
       - to:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
         ports:
           - { protocol: UDP, port: 53 }
           - { protocol: TCP, port: 53 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: sleep-egress-to-httpbin
     namespace: secure-demo
   spec:
     podSelector:
       matchLabels: { app: sleep }
     policyTypes: [Egress]
     egress:
       - to:
           - podSelector:
               matchLabels: { app: httpbin }
         ports:
           - { protocol: TCP, port: 80 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: httpbin-ingress-from-sleep
     namespace: secure-demo
   spec:
     podSelector:
       matchLabels: { app: httpbin }
     policyTypes: [Ingress]
     ingress:
       - from:
           - podSelector:
               matchLabels: { app: sleep }
         ports:
           - { protocol: TCP, port: 80 }
   ```

   ```bash
   kubectl apply -f allow-sleep-to-httpbin.yaml
   kubectl -n secure-demo exec deploy/sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get
   ```

   Salida esperada:

   ```
   200
   ```

4. Observá el veredicto de política en vivo con Hubble (el observabilidad de Cilium). Habilitalo y mirá los drops:

   ```bash
   cilium hubble enable
   cilium hubble port-forward &
   # generá un flujo prohibido: httpbin intentando salir a sleep (no hay regla)
   kubectl -n secure-demo exec deploy/httpbin -- \
     curl -s --max-time 3 http://sleep:80 -o /dev/null || true
   hubble observe --namespace secure-demo --verdict DROPPED --last 5
   ```

   Salida esperada (recortada):

   ```
   ... secure-demo/httpbin ... -> secure-demo/sleep ... Policy denied DROPPED (TCP Flags: SYN)
   ```

**Preguntas de verificación (E2)**

- **E2-P1.** En el paso 2, ¿por qué falló primero la **resolución DNS** y no la conexión HTTP? ¿Qué te dice eso sobre el orden de evaluación de un default-deny de egress?
- **E2-P2.** Las `NetworkPolicy` operan en L3/L4. Nombrá **dos ataques** que esta política *no* detiene y que motivan agregar mTLS y autorización L7 encima.
- **E2-P3.** La política `httpbin-ingress-from-sleep` usa `podSelector: {app: sleep}`. Si un atacante despliega un Pod propio y le pone la label `app=sleep`, ¿lo dejaría pasar? ¿Qué propiedad de las labels hace que esto sea insuficiente como identidad?

---

## Ejercicio 3 — mTLS automático y transparente con un service mesh

**Objetivo:** que el cifrado y la **identidad criptográfica** entre servicios sean un default de plataforma, sin tocar el código de las apps. Instalamos Istio (modo sidecar), forzamos `STRICT` mTLS y verificamos que la identidad viaja en el certificado.

1. Instalá el control plane con el perfil `demo` y habilitá la inyección de sidecar en el namespace:

   ```bash
   istioctl install --set profile=demo -y
   kubectl label namespace secure-demo istio-injection=enabled --overwrite
   kubectl -n secure-demo rollout restart deploy httpbin sleep
   kubectl -n secure-demo rollout status deploy/httpbin
   ```

   Ahora cada Pod tiene 2 contenedores (app + `istio-proxy`):

   ```bash
   kubectl -n secure-demo get pod
   ```

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7f9d5c8b7c-abcde   2/2     Running   0          25s
   sleep-6b8c9d7f6d-fghij     2/2     Running   0          25s
   ```

   > **Nota de plataforma:** el mesh necesita atravesar tus `NetworkPolicy`. En sidecar mode el tráfico sale del Pod ya cifrado por el proxy, pero sigue siendo TCP:80 entre Pods, así que las reglas del E2 conviven. Para producción con `STRICT`, ajustá las políticas a los puertos del sidecar y permití el acceso al control plane (`istiod`, puerto 15012). Este es exactamente el tipo de fricción que como Platform Engineer resolvés con un template, no el equipo de app.

2. Por defecto Istio arranca en modo `PERMISSIVE` (acepta texto plano *y* mTLS, para migraciones sin downtime). Forzá `STRICT` a nivel mesh con un `PeerAuthentication` en el namespace `istio-system`… pero primero hacelo por namespace para ver el efecto acotado:

   ```yaml
   # strict-mtls.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: secure-demo
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f strict-mtls.yaml
   ```

3. **Verificá que el tráfico dentro del mesh sigue funcionando** (los sidecars negocian mTLS solos):

   ```bash
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get
   ```

   ```
   200
   ```

4. **Verificá que un cliente FUERA del mesh es rechazado.** Desplegá un Pod sin sidecar en otro namespace e intentá alcanzar `httpbin` en texto plano:

   ```bash
   kubectl create namespace outside
   kubectl -n outside run raw --image=curlimages/curl --restart=Never -- \
     sleep infinity
   kubectl -n outside wait --for=condition=Ready pod/raw
   kubectl -n outside exec raw -- \
     curl -s --max-time 5 http://httpbin.secure-demo:8000/get -o /dev/null -w "%{http_code}\n" \
     || echo "RESET / REJECTED"
   ```

   Salida esperada (bajo `STRICT` el sidecar de httpbin corta el TLS handshake del texto plano):

   ```
   curl: (56) Recv failure: Connection reset by peer
   RESET / REJECTED
   ```

5. **Confirmá el estado de mTLS con herramientas de diagnóstico**, no de fe:

   ```bash
   HTTPBIN=$(kubectl -n secure-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   istioctl experimental describe pod -n secure-demo $HTTPBIN
   ```

   Salida esperada (recortada):

   ```
   Pod: httpbin-7f9d5c8b7c-abcde
      Pod Revision: default
      Pod Ports: 80 (httpbin), 15090 (istio-proxy)
   --------------------
   Service: httpbin
      Port: http 8000/HTTP targets pod port 80
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
   Applied PeerAuthentication:
      default.secure-demo
   ```

6. **Extraé la identidad del certificado** — acá se ve que el mesh emite un **SPIFFE ID** por workload, derivado de la ServiceAccount. Este es el corazón del tema:

   ```bash
   istioctl proxy-config secret $HTTPBIN -n secure-demo -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d \
     | openssl x509 -noout -text \
     | grep -A1 'Subject Alternative Name'
   ```

   Salida esperada:

   ```
   X509v3 Subject Alternative Name: critical
       URI:spiffe://cluster.local/ns/secure-demo/sa/httpbin
   ```

**Preguntas de verificación (E3)**

- **E3-P1.** Diferenciá `PERMISSIVE` de `STRICT`. ¿Por qué `PERMISSIVE` es el default de Istio y en qué escenario de migración es imprescindible?
- **E3-P2.** En el paso 4 el rechazo lo produce el **sidecar de httpbin**, no una `NetworkPolicy`. Explicá por qué mTLS `STRICT` y `NetworkPolicy` son controles complementarios y no redundantes (pensá en un atacante *dentro* del mesh vs. *fuera*).
- **E3-P3.** El SAN del certificado es `spiffe://cluster.local/ns/secure-demo/sa/httpbin`. Descomponé cada segmento del URI. ¿De dónde saca Istio el material para emitir ese certificado y quién lo firma?
- **E3-P4.** El `Service` del E1 nombra su puerto `http`. ¿Qué pasa con la detección de protocolo y las políticas L7 si ese puerto se llamara `tcp-80` o no tuviera nombre?

---

## Ejercicio 4 — Autorización L7 por identidad de workload (`AuthorizationPolicy`)

**Objetivo:** pasar de "el canal está cifrado y ambas puntas tienen identidad" a "**solo esta identidad puede hacer esta acción**". mTLS autentica; la autorización decide. Este es el control que convierte identidad en política.

1. Aplicá un **default-deny de autorización** para todo `secure-demo`. Una `AuthorizationPolicy` con `spec` vacío (sin `rules`) deniega todo lo que llega a los workloads seleccionados:

   ```yaml
   # authz-deny-all.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-all
     namespace: secure-demo
   spec:
     {}          # sin action ni rules => ALLOW con lista vacía => deniega todo
   ```

   ```bash
   kubectl apply -f authz-deny-all.yaml
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get
   ```

   Salida esperada (Envoy responde 403 *después* de un mTLS exitoso):

   ```
   403
   ```

   ```bash
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s http://httpbin:8000/get
   ```

   ```
   RBAC: access denied
   ```

2. Autorizá explícitamente a la identidad de `sleep`, y **solo** a los métodos `GET`. Fijate que `principals` usa la identidad SPIFFE del certificado que viste en el E3 — no una IP, no una label:

   ```yaml
   # authz-allow-sleep-get.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-allow-sleep
     namespace: secure-demo
   spec:
     selector:
       matchLabels: { app: httpbin }
     action: ALLOW
     rules:
       - from:
           - source:
               principals:
                 - "cluster.local/ns/secure-demo/sa/sleep"
         to:
           - operation:
               methods: ["GET"]
               paths: ["/get", "/status/*"]
   ```

   ```bash
   kubectl apply -f authz-allow-sleep-get.yaml
   ```

3. Verificá la matriz de acceso — mismo cliente, distintos métodos y paths:

   ```bash
   # GET /get => permitido
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "GET /get      -> %{http_code}\n" http://httpbin:8000/get
   # DELETE /delete => denegado (método no autorizado)
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "DELETE /delete-> %{http_code}\n" -X DELETE http://httpbin:8000/delete
   # GET /headers => denegado (path no autorizado)
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "GET /headers  -> %{http_code}\n" http://httpbin:8000/headers
   ```

   Salida esperada:

   ```
   GET /get      -> 200
   DELETE /delete-> 403
   GET /headers  -> 403
   ```

4. **Probá la propiedad clave:** una identidad distinta es rechazada aunque esté dentro del mesh. Inyectá el sidecar en el namespace `outside`, desplegá otro `sleep` con **otra ServiceAccount** y verificá que no pasa:

   ```bash
   kubectl label namespace outside istio-injection=enabled --overwrite
   kubectl -n outside create serviceaccount intruso
   kubectl -n outside run intruso --image=curlimages/curl \
     --overrides='{"spec":{"serviceAccountName":"intruso"}}' \
     --restart=Never -- sleep infinity
   kubectl -n outside wait --for=condition=Ready pod/intruso --timeout=90s
   kubectl -n outside exec intruso -c intruso -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin.secure-demo:8000/get
   ```

   Salida esperada (mTLS OK, pero el `principal` no está en la allow-list):

   ```
   403
   ```

5. Diagnosticá una denegación mirando los logs del sidecar de `httpbin` (el flag `rbac[...]` te dice qué política actuó):

   ```bash
   kubectl -n secure-demo logs deploy/httpbin -c istio-proxy | grep -i rbac | tail -1
   ```

   ```
   ... "response_flags":"-" ... "rbac_denied" ... "GET" "/headers" ...
   ```

**Preguntas de verificación (E4)**

- **E4-P1.** En el paso 4 el `intruso` completó el handshake **mTLS** correctamente (tiene un SVID válido emitido por el mesh) y aun así recibió `403`. Explicá la diferencia entre **authentication** y **authorization** usando este resultado concreto.
- **E4-P2.** El campo `principals` matchea `cluster.local/ns/secure-demo/sa/sleep`. Compará la robustez de esto contra la `NetworkPolicy` del E2 que usaba `podSelector: {app: sleep}`. ¿Por qué un atacante puede falsificar la label pero no el `principal`?
- **E4-P3.** ¿Cuál es la diferencia semántica entre una `AuthorizationPolicy` con `action: DENY` y una con `action: ALLOW`? Si aplicás las dos y una request matchea ambas, ¿cuál gana y por qué ese orden es una decisión de seguridad "fail-safe"?
- **E4-P4.** El `deny-all` del paso 1 y el `allow-sleep` del paso 2 conviven. ¿Por qué el segundo "gana" para el tráfico de `sleep` sin que tengas que borrar el primero? (pista: cómo se combinan las políticas `ALLOW`).

---

## Ejercicio 5 — La raíz de confianza: SPIFFE/SPIRE y `cert-manager`

**Objetivo:** entender de dónde sale la identidad que usaste en E3/E4 y cómo, en una plataforma seria, esa raíz de confianza se gestiona explícitamente en vez de depender de la CA self-signed que Istio genera por defecto. Este ejercicio es más conceptual/observacional: vas a *inspeccionar* la cadena de confianza y (opcionalmente) reemplazar la CA.

1. Recapitulá el modelo SPIFFE que ya estás usando. Cada workload tiene un **SPIFFE ID** (el URI del SAN) y un **SVID** (SPIFFE Verifiable Identity Document — el certificado X.509 de vida corta). Mirá la validez del SVID de un sidecar:

   ```bash
   HTTPBIN=$(kubectl -n secure-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret $HTTPBIN -n secure-demo -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -dates -subject
   ```

   Salida esperada (SVID de ~24 h — rotación automática):

   ```
   notBefore=...
   notAfter=...            # ~24h después de notBefore
   subject=
   ```

2. Identificá **quién firma** ese SVID. En un Istio default es el CA embebido en `istiod` (`istio-ca-secret` en `istio-system`), una CA self-signed:

   ```bash
   kubectl -n istio-system get secret istio-ca-secret \
     -o jsonpath='{.data.ca-cert\.pem}' | base64 -d \
     | openssl x509 -noout -subject -issuer
   ```

   ```
   subject=O=cluster.local
   issuer=O=cluster.local          # self-signed: subject == issuer
   ```

3. **El problema de plataforma:** esa CA self-signed no encadena a ninguna raíz corporativa, no es auditable ni rotable con tu PKI, y si dos clusters usan CAs distintas no pueden hacer trust federado. El patrón de producción es delegar la emisión a **`cert-manager`** vía **`istio-csr`**, de modo que el `trustDomain` de tu mesh cuelgue de tu Issuer (Vault, un intermediate CA, ACME, etc.). Instalá el andamiaje (demostrativo, con un self-signed Issuer que representa tu PKI):

   ```bash
   helm repo add jetstack https://charts.jetstack.io && helm repo update
   helm install cert-manager jetstack/cert-manager \
     --namespace cert-manager --create-namespace \
     --set crds.enabled=true
   kubectl -n cert-manager rollout status deploy/cert-manager
   ```

   ```yaml
   # mesh-ca.yaml — un intermediate que representaría TU raíz corporativa
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata:
     name: selfsigned-root
     namespace: istio-system
   spec:
     selfSigned: {}
   ---
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: istio-ca
     namespace: istio-system
   spec:
     isCA: true
     duration: 87600h
     secretName: istio-ca
     commonName: istio-ca
     subject:
       organizations: ["cluster.local"]
     issuerRef:
       name: selfsigned-root
       kind: Issuer
   ---
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata:
     name: istio-ca
     namespace: istio-system
   spec:
     ca:
       secretName: istio-ca
   ```

   ```bash
   kubectl apply -f mesh-ca.yaml
   ```

   > **Alcance del lab:** el cableado completo requiere desplegar el componente `cert-manager/istio-csr` y reinstalar Istio con `--set global.caAddress=cert-manager-istio-csr.cert-manager.svc:443`. Para no reconstruir el mesh, lo dejamos como el "paso siguiente" documentado; lo que importa que entiendas es *qué mueve* respecto de los pasos 1–2: la línea `issuer` de los SVID pasa de la CA self-signed de `istiod` a **tu** `Issuer`.

4. Distinguí los planos de trust con Linkerd como contrapunto (no lo instalamos; es una pregunta de arquitectura). Linkerd también emite identidades por ServiceAccount y hace mTLS automático, pero su modelo de trust y su footprint difieren de Istio; SPIFFE/SPIRE es el estándar CNCF *agnóstico* que ambos pueden consumir como fuente de identidad.

5. Limpieza:

   ```bash
   kind delete cluster --name sec-mesh
   ```

**Preguntas de verificación (E5)**

- **E5-P1.** ¿Qué son, respectivamente, un **trust domain**, un **SPIFFE ID** y un **SVID**? Ubicá cada uno en la salida que obtuviste en E3-paso 6 y E5-paso 1.
- **E5-P2.** Los SVID del paso 1 duran ~24 h y rotan solos. ¿Qué ventaja de seguridad da la vida corta frente a un certificado de larga duración, y qué requisito de infraestructura impone (pensá qué pasa si el emisor no está disponible)?
- **E5-P3.** ¿Qué gana concretamente una plataforma al mover la CA del mesh de la self-signed de `istiod` a `cert-manager` + `istio-csr`? Dá al menos dos beneficios operativos.
- **E5-P4.** SPIFFE define identidad de forma agnóstica del mesh. ¿Por qué es valioso para un Platform Engineer que la identidad de workload sea un estándar (SPIFFE) y no una feature propietaria de Istio o Linkerd?

---

## Respuestas

<details>
<summary><strong>Ver respuestas y explicaciones (E1–E5)</strong></summary>

### Ejercicio 1

**E1-P1.** Kubernetes no provee, por defecto, ni **confidencialidad/integridad del tráfico** (el pod-to-pod va en texto plano sobre la red del CNI) ni **identidad de workload mutuamente verificable** (un servicio no puede probar criptográficamente quién es el que lo llama). En el paso 5 demostraste lo primero: el header `X-Secret: PLATAFORMA-1234` apareció legible en la captura `tcpdump`. Cualquier actor con acceso al datapath (un nodo comprometido, un sniffer en la red del CNI, un sidecar malicioso) lo lee.

**E1-P2.** Nada se lo impide: por defecto el modelo de red de Kubernetes es *flat* — todo Pod puede alcanzar a todo Pod y a todo `Service` por su ClusterIP/DNS, sin autenticación. Esto viola **least privilege** porque el acceso es implícito y universal en vez de explícito y mínimo: el servicio queda expuesto a todo el cluster aunque solo un cliente legítimo deba usarlo, maximizando la superficie de *lateral movement* tras un compromiso inicial.

**E1-P3.** Porque la ServiceAccount **es** la identidad del workload en Kubernetes, y es de ahí de donde el mesh (y SPIFFE) derivan el certificado/SPIFFE ID (`.../sa/<serviceaccount>`). Si todos los Pods comparten la SA `default`, todos obtienen la **misma identidad criptográfica** y se vuelve imposible escribir autorización por servicio (E4) o rotar/revocar credenciales por workload. Una SA por workload es el prerequisito estructural de toda política basada en identidad.

### Ejercicio 2

**E2-P1.** Falló primero el **DNS** porque `curl` necesita resolver `httpbin` → ClusterIP *antes* de abrir la conexión HTTP, y el default-deny de egress también bloquea el tráfico UDP/TCP:53 hacia el `kube-dns`/CoreDNS de `kube-system`. La lección: un default-deny de egress corta **toda** salida, incluida la infraestructura que las apps dan por sentada (DNS, y en clusters reales también el API server, NTP, metadata). Por eso la regla `allow-dns` es obligatoria y suele ser parte del baseline de plataforma.

**E2-P2.** Ejemplos: (a) un Pod *autorizado* por la política (p. ej. otro `sleep` legítimo) igualmente ve el tráfico en **texto plano** — L4 no cifra; (b) **spoofing de identidad**: NetworkPolicy decide por selector de labels/namespace, no por identidad criptográfica, así que un Pod que consiga las labels correctas pasa; (c) ataques L7 (métodos/paths no autorizados, header smuggling) son invisibles a L3/L4. Todo esto motiva mTLS (E3) para cifrado+identidad y `AuthorizationPolicy` (E4) para control L7.

**E2-P3.** Sí, lo dejaría pasar: `NetworkPolicy` matchea por **labels**, y las labels son metadata mutable y no autenticada — cualquiera con permiso de crear Pods en el namespace puede ponerle `app=sleep` a su Pod. Las labels identifican *pertenencia a un grupo de scheduling/routing*, no una identidad probada. Por eso la segmentación L3/L4 es necesaria pero no suficiente: la identidad fuerte llega recién con el SPIFFE ID del certificado mTLS (E3/E4), que el atacante no puede falsificar sin la clave privada emitida por la CA del mesh.

### Ejercicio 3

**E3-P1.** `STRICT` obliga a que *todo* el tráfico entrante al workload sea mTLS; el texto plano se rechaza. `PERMISSIVE` acepta **ambos**: mTLS si el cliente lo ofrece, texto plano si no. `PERMISSIVE` es el default porque permite una **migración sin downtime**: al inyectar sidecars incrementalmente, los clientes ya migrados hablan mTLS mientras los que todavía no tienen sidecar siguen funcionando en claro; recién cuando todo el tráfico es mTLS (verificable en telemetría) se pasa a `STRICT`. Ir directo a `STRICT` en un mesh mixto rompe todo el tráfico legacy.

**E3-P2.** Son complementarios porque cubren atacantes distintos. mTLS `STRICT` frena al atacante **fuera del mesh** (sin sidecar/sin certificado no completa el handshake — paso 4) y garantiza cifrado+identidad *dentro*. Pero mTLS por sí solo, una vez que ambas puntas tienen certificado válido, deja pasar el tráfico; no restringe *quién con identidad válida* puede hablar con quién. `NetworkPolicy` (y luego `AuthorizationPolicy`) aportan esa restricción y además siguen operando en el plano L3/L4 aunque el sidecar sea evadido o esté mal configurado — defensa en profundidad: un control no depende del otro.

**E3-P3.** `spiffe://` = esquema SPIFFE; `cluster.local` = el **trust domain** del mesh (raíz de nombres bajo una misma CA); `ns/secure-demo` = el namespace; `sa/httpbin` = la ServiceAccount. Istio arma este URI a partir de la ServiceAccount del Pod (vía su token proyectado) y lo pone como **SAN URI** del certificado. Lo **firma la CA del mesh**: por defecto el CA embebido en `istiod` (self-signed, ver E5), o `cert-manager` si delegaste la emisión.

**E3-P4.** Istio hace **protocol detection** apoyándose en la convención de nombres de puerto del `Service`: un puerto llamado `http`, `http2`, `grpc`, `tls`, etc. le dice a Envoy que aplique el filtro L7 correspondiente. Si el puerto se llamara `tcp-80` o no tuviera nombre, Istio lo trataría como **TCP opaco (L4)**: el mTLS de transporte seguiría funcionando, pero **perderías toda capacidad L7** — enrutamiento por path/método, y crucialmente las `AuthorizationPolicy` con `methods`/`paths` del E4 no podrían aplicarse (solo quedarían reglas L4). Nombrar bien los puertos es un requisito, no un estilo.

### Ejercicio 4

**E4-P1.** **Authentication** responde *"¿quién sos?"* y se resolvió en el handshake mTLS: el `intruso` presentó un SVID válido firmado por la CA del mesh, con SPIFFE ID `.../sa/intruso` — su identidad quedó probada. **Authorization** responde *"¿tenés permiso para hacer esto?"* y la evaluó la `AuthorizationPolicy` de `httpbin`, que solo lista a `.../sa/sleep` en `principals`. El `intruso` está *autenticado pero no autorizado* → `403`. Es la separación exacta que buscás en zero-trust: identidad fuerte primero, decisión de acceso explícita después.

**E4-P2.** El `principal` proviene del **SPIFFE ID del certificado mTLS**, cuya clave privada fue emitida por la CA del mesh a ese workload específico y nunca sale del sidecar. Falsificarlo exige robar la clave o comprometer la CA — un ataque de otro orden de magnitud. La label `app=sleep` de la `NetworkPolicy`, en cambio, es texto mutable que cualquiera con permiso de crear Pods asigna libremente. Por eso `principals` es una **identidad criptográficamente verificada** y el `podSelector` es apenas un agrupamiento declarativo.

**E4-P3.** `ALLOW` define lo permitido: si existe alguna política `ALLOW` que seleccione al workload, todo lo que **no** matchee ninguna regla `ALLOW` se deniega. `DENY` define excepciones prohibidas explícitamente. El orden de evaluación de Istio es **fail-safe**: se evalúan primero las `DENY` — si alguna matchea, se rechaza *inmediatamente*, aunque una `ALLOW` también matchee. Es decir, **`DENY` gana**. Esto es deliberado: una regla que dice "esto nunca" no debe poder ser anulada por accidente por una `ALLOW` demasiado amplia.

**E4-P4.** Porque las políticas `ALLOW` se **combinan por unión (OR)**: una request se admite si matchea *cualquier* regla `ALLOW` aplicable. El `deny-all` del paso 1 no es un `action: DENY`; es un `ALLOW` con lista vacía (no permite nada por sí mismo). Al agregar `httpbin-allow-sleep`, el tráfico de `sleep` ahora matchea una regla `ALLOW` y pasa, mientras el resto sigue sin matchear ninguna y queda denegado. No hace falta borrar el `deny-all`: actúa como el "piso" default-deny sobre el que vas sumando permisos explícitos.

### Ejercicio 5

**E5-P1.** El **trust domain** es la raíz de nombres/confianza bajo una misma CA — acá `cluster.local` (el `O=cluster.local` del issuer en E5-paso 2 y el primer segmento del URI en E3-paso 6). El **SPIFFE ID** es el nombre de identidad del workload: `spiffe://cluster.local/ns/secure-demo/sa/httpbin` (el SAN URI de E3-paso 6). El **SVID** es el documento que *prueba* esa identidad — el certificado X.509 de vida corta cuyas fechas viste en E5-paso 1, que porta el SPIFFE ID en su SAN y está firmado por la CA del trust domain.

**E5-P2.** Un SVID de vida corta reduce drásticamente la **ventana de abuso** de una credencial filtrada (expira en horas, no en meses) y elimina en la práctica la necesidad de listas de revocación (CRL/OCSP): en vez de revocar, se deja expirar. El requisito de infraestructura es una **CA/emisor de alta disponibilidad y rotación automática**: como los certificados caducan seguido, si el emisor (istiod / SPIRE / cert-manager) no está disponible cuando toca renovar, los workloads pierden su SVID y el mTLS empieza a fallar. Vida corta compra seguridad a cambio de dependencia operativa del plano de identidad.

**E5-P3.** Beneficios de mover la CA a `cert-manager` + `istio-csr`: (1) **encadenamiento a la PKI corporativa** — el trust domain cuelga de una raíz/intermediate real (Vault, ACME, tu CA), en vez de una self-signed aislada; (2) **rotación y auditoría gestionadas** por cert-manager con sus `Certificate`/`Issuer` declarativos y sus métricas; (3) **trust federado multi-cluster** — varios clusters que encadenan a la misma raíz pueden validar mutuamente identidades sin compartir claves de mesh; (4) **separación de responsabilidades** — la política de emisión deja de estar embebida en `istiod`. Cualquier dos de estos alcanzan.

**E5-P4.** Porque SPIFFE desacopla la **identidad de workload** de la implementación del mesh. Para el Platform Engineer eso significa: (1) puede cambiar Istio ↔ Linkerd, o correr múltiples runtimes, sin re-emitir identidades ni reescribir políticas de confianza; (2) puede extender la misma identidad a workloads *fuera* de Kubernetes (VMs, funciones) vía SPIRE, unificando la raíz de confianza; (3) evita lock-in propietario y apoya la capability en un estándar CNCF interoperable. La identidad se vuelve un servicio de plataforma estable por debajo de herramientas que van y vienen.

</details>

---

### Fuentes oficiales

- CNCF — *Cloud Native Platform Engineering Associate (CNPA) Curriculum*: https://github.com/cncf/curriculum
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Istio — *Mutual TLS / Peer Authentication*: https://istio.io/latest/docs/concepts/security/#mutual-tls-authentication y https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Authorization Policy*: https://istio.io/latest/docs/reference/config/security/authorization-policy/ y https://istio.io/latest/docs/tasks/security/authorization/authz-http/
- SPIFFE/SPIRE — *SPIFFE Concepts (SPIFFE ID, SVID, Trust Domain)*: https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- cert-manager — *istio-csr*: https://cert-manager.io/docs/usage/istio-csr/
- Cilium — *Network Policy & Hubble*: https://docs.cilium.io/en/stable/security/policy/ y https://docs.cilium.io/en/stable/observability/hubble/
- Linkerd — *Automatic mTLS*: https://linkerd.io/2/features/automatic-mtls/