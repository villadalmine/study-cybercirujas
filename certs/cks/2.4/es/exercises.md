# Ejercicios — 2.4 Implementar Cifrado Pod-a-Pod (Cilium, Istio)

**Certificación:** CKS 1.34 · **Peso del dominio:** 5%

Estos son ejercicios guiados prácticos. Cada bloque termina con preguntas de verificación; las respuestas están colapsadas al final. No leas las respuestas hasta haber ejecutado el bloque.

---

## Preparación del laboratorio

Necesitás un clúster **multi-nodo**. El cifrado pod-a-pod en Cilium solo se aplica al tráfico que sale del nodo, así que un clúster de un solo nodo hará que cada paso de verificación pase silenciosamente por la razón equivocada.

```bash
cat <<'EOF' > kind-enc.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true      # we install Cilium ourselves
  kubeProxyMode: none          # Cilium will replace kube-proxy
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --name enc --config kind-enc.yaml
```

Instalá Cilium **sin** cifrado primero — el primer ejercicio depende de que el tráfico esté en texto plano.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set k8sServiceHost=enc-control-plane \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=true

kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl get nodes
```

Lista de requisitos antes de continuar:

| Requisito | Comprobación |
|---|---|
| Kernel con soporte WireGuard (5.6+, o módulo `wireguard`) | `grep -i wireguard /lib/modules/$(uname -r)/modules.builtin` o `modprobe wireguard` |
| `helm`, `kubectl`, `jq`, `openssl` en el cliente | `which helm kubectl jq openssl` |
| Todos los nodos en `Ready` | `kubectl get nodes` |

---

## Ejercicio 1 — Demostrar que el tráfico pod-a-pod es texto plano por defecto

**Objetivo:** establecer una línea base. No podés afirmar que cifraste algo si nunca lo viste sin cifrar.

1. Creá el namespace del laboratorio y un servidor HTTP canario fijado a `enc-worker`:

```bash
kubectl create ns enc-lab

kubectl -n enc-lab run canary \
  --image=hashicorp/http-echo \
  --port=5678 \
  --overrides='{"spec":{"nodeName":"enc-worker"}}' \
  -- -listen=:5678 -text=CKS-PLAINTEXT-CANARY
```

2. Creá un pod cliente en el **otro** worker, para que el tráfico deba cruzar la red:

```bash
kubectl -n enc-lab run probe \
  --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeName":"enc-worker2"}}' \
  -- sleep infinity

kubectl -n enc-lab wait --for=condition=Ready pod/canary pod/probe --timeout=120s
kubectl -n enc-lab get pods -o wide
```

3. Guardá la IP del canario:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
echo "$CANARY_IP"
```

4. Desplegá un sniffer con host networking en el nodo del servidor. Esta es la única forma confiable de ver qué circula realmente por el cable:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sniffer
  namespace: enc-lab
spec:
  nodeName: enc-worker
  hostNetwork: true
  tolerations:
    - operator: Exists
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

kubectl -n enc-lab wait --for=condition=Ready pod/sniffer --timeout=120s
```

5. **Terminal A** — iniciá la captura. Incluí el puerto del overlay VXLAN, el puerto de WireGuard y ESP para que el mismo comando sirva en todos los ejercicios posteriores:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 30 tcpdump -ni any -A -s0 -l \
  'udp port 8472 or udp port 51871 or esp or tcp port 5678'
```

6. **Terminal B** — generá una petición:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

7. Leé la salida de la Terminal A. Buscá la cadena literal `CKS-PLAINTEXT-CANARY` y las cabeceras de los paquetes a su alrededor.

**Preguntas**

- **Q1.1** ¿Apareció la cadena `CKS-PLAINTEXT-CANARY` en la captura? ¿Qué prueba eso sobre el data path por defecto de Cilium?
- **Q1.2** ¿Qué protocolo de transporte y qué puerto llevaron la petición entre los dos nodos? ¿Cómo se llama ese mecanismo?
- **Q1.3** El tráfico estaba *encapsulado*. Explicá en una frase por qué la encapsulación no es cifrado.
- **Q1.4** ¿Por qué el ejercicio forzó a `canary` y `probe` a dos nodos distintos con `nodeName`? ¿Qué habría mostrado una prueba en el mismo nodo una vez habilitado el cifrado?
- **Q1.5** ¿Por qué el sniffer necesita `hostNetwork: true` en lugar de solo `NET_RAW` en el namespace del laboratorio?

---

## Ejercicio 2 — Habilitar el cifrado transparente de Cilium con WireGuard

**Objetivo:** encender la opción que el currículum de CKS nombra explícitamente, y entender su radio de impacto.

1. Habilitá el cifrado WireGuard actualizando el release de Cilium. Reutilizá los valores existentes para no perder la configuración de reemplazo de kube-proxy:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
```

2. Confirmá que el agente lo tomó. Cilium 1.16+ trae la CLI interna del agente como `cilium-dbg`; las versiones anteriores usan `cilium`:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i -A2 Encryption
```

Forma esperada:

```
Encryption: Wireguard [NodeEncryption: Disabled, cilium_wg0 (Pubkey: <key>, Port: 51871, Peers: 2)]
```

3. Inspeccioná el dispositivo del túnel y sus peers en un nodo:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
kubectl -n enc-lab exec sniffer -- ip -d link show cilium_wg0
kubectl -n enc-lab exec sniffer -- wg show all 2>/dev/null || echo "wg tool not on host"
```

4. Confirmá que `Peers` es igual al número de nodos *distintos del propio* que participan, y que todos los agentes reportan el mismo tipo de cifrado:

```bash
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -- cilium-dbg status | grep -i '^Encryption'
done
```

**Preguntas**

- **Q2.1** ¿Qué interfaz de red crea Cilium para WireGuard, y qué puerto UDP usa por defecto?
- **Q2.2** En un clúster de 3 nodos, ¿cuántos `Peers` debería reportar cada agente, y por qué ese número no es 3?
- **Q2.3** En el status aparece `NodeEncryption: Disabled`. ¿Qué tráfico queda entonces *sin* cifrar, y qué valor de Helm lo cambia?
- **Q2.4** Habilitaste el cifrado con `helm upgrade --reuse-values`. ¿Qué se rompe si omitís `--reuse-values` en este laboratorio?
- **Q2.5** Cilium llama a esto cifrado "transparente". ¿Transparente para quién — nombrá las dos cosas que **no** tuvieron que cambiar.

---

## Ejercicio 3 — Verificar el cifrado en el cable

**Objetivo:** nunca confíes en una línea de status. Demostralo con paquetes.

1. **Terminal A** — repetí la captura exacta del Ejercicio 1:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 30 tcpdump -ni any -A -s0 -l \
  'udp port 8472 or udp port 51871 or esp or tcp port 5678'
```

2. **Terminal B** — regenerá el tráfico:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

3. Compará contra la línea base. Después capturá en el *interior* del túnel para ver el mismo flujo en claro:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 20 tcpdump -ni cilium_wg0 -A -s0 -l 'tcp port 5678'
```

Regenerá el tráfico en la Terminal B mientras esto corre.

4. Ahora hacé la prueba negativa — tráfico en el mismo nodo. Programá un segundo cliente en el nodo **del servidor**:

```bash
kubectl -n enc-lab run probe-local \
  --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeName":"enc-worker"}}' \
  -- sleep infinity

kubectl -n enc-lab wait --for=condition=Ready pod/probe-local --timeout=120s
```

Capturá en el dispositivo WireGuard, después enviá la petición:

```bash
# Terminal A
kubectl -n enc-lab exec sniffer -- timeout 20 tcpdump -ni cilium_wg0 -c 5 -A -s0

# Terminal B
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe-local -- curl -sS "http://$CANARY_IP:5678/"
```

5. Revisá los contadores de error, que es lo que buscarías con grep en un incidente real:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg statedb health | grep -i -E 'encrypt|wireguard' || true
```

**Preguntas**

- **Q3.1** En el paso 2, ¿seguía siendo visible `CKS-PLAINTEXT-CANARY`? ¿Cómo se veían en su lugar los paquetes entre nodos?
- **Q3.2** En el paso 3 capturaste en `cilium_wg0` y el texto plano reapareció. ¿Por qué eso es lo esperado y no una falla de seguridad?
- **Q3.3** En el paso 4, ¿apareció algún paquete en `cilium_wg0`? Explicá el resultado en términos de dónde se ubica la frontera de cifrado.
- **Q3.4** Un colega concluye "Cilium WireGuard cifra todo el tráfico pod-a-pod del clúster". Corregí la afirmación con precisión.
- **Q3.5** Necesitás *garantizar* que ningún tráfico de pods sin cifrar pueda salir de un nodo, no solamente que el cifrado esté disponible. ¿Qué funcionalidad de Cilium se ocupa de eso, y cuál es su principal riesgo operativo?

---

## Ejercicio 4 — La alternativa IPsec y la rotación de claves

**Objetivo:** IPsec es el otro modo de cifrado transparente de Cilium. La parte relevante para el examen es el secret de la clave y sus reglas de rotación.

1. Deshabilitá WireGuard y cambiá a IPsec. IPsec necesita un secret con clave precompartida **antes** de que los agentes reinicien:

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system get secret cilium-ipsec-keys -o jsonpath='{.data.keys}' | base64 -d
```

2. Reconfigurá Cilium:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=ipsec

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s

kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i -A2 Encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

3. Verificá en el cable. IPsec usa ESP, no un puerto UDP de túnel:

```bash
# Terminal A
kubectl -n enc-lab exec sniffer -- timeout 30 tcpdump -ni any -A -s0 -l 'esp or tcp port 5678'

# Terminal B
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

4. Mirá las asociaciones de seguridad del kernel que instaló Cilium:

```bash
kubectl -n enc-lab exec sniffer -- ip xfrm state | head -30
kubectl -n enc-lab exec sniffer -- ip xfrm policy | head -20
```

5. Rotá la clave. La regla es: **incrementar el ID de clave**, mantener el mismo nombre de secret, y dejar que Cilium converja:

```bash
NEW_KEY="4 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system patch secret cilium-ipsec-keys \
  --type merge \
  -p "{\"stringData\":{\"keys\":\"$NEW_KEY\"}}"

sleep 20
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

6. Vigilá los errores de descifrado durante y después de la rotación:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status | grep -i -E 'error|keys in use'
```

**Preguntas**

- **Q4.1** Descomponé la cadena de clave `3 rfc4106(gcm(aes)) <hex> 128`. ¿Qué es cada uno de los cuatro campos?
- **Q4.2** ¿Cuál es el rango válido del ID de clave, y qué pasa si rotás más allá de él?
- **Q4.3** ¿Por qué el ID de clave *debe* cambiar en la rotación en lugar de solo el material de clave?
- **Q4.4** En el paso 3, ¿qué protocolo IP llevó el tráfico de los pods, y qué muestra `tcpdump` para el payload?
- **Q4.5** Dá una ventaja operativa de WireGuard sobre IPsec en este caso, y una razón por la que una organización podría estar obligada igualmente a elegir IPsec.
- **Q4.6** Ambos modos son "transparentes". ¿Qué única cosa fallan ambos en proteger que sí protege un mesh de capa de aplicación?

---

## Ejercicio 5 — Instalar Istio y meter una carga de trabajo en el mesh

**Objetivo:** subir en el stack. Cilium cifra nodo-a-nodo; el mTLS de Istio cifra y *autentica* carga-de-trabajo-a-carga-de-trabajo.

1. Instalá Istio con el perfil por defecto:

```bash
istioctl install --set profile=default -y
kubectl -n istio-system get pods
istioctl version
```

2. Creá dos namespaces — uno dentro del mesh, otro deliberadamente afuera:

```bash
kubectl create ns mesh-a
kubectl create ns plain

kubectl label ns mesh-a istio-injection=enabled
kubectl get ns mesh-a plain --show-labels
```

3. Desplegá las cargas de trabajo de ejemplo. `httpbin` es el servidor dentro del mesh; `sleep` es un cliente, desplegado dos veces — una inyectado, otra no:

```bash
kubectl -n mesh-a apply -f samples/httpbin/httpbin.yaml
kubectl -n mesh-a apply -f samples/sleep/sleep.yaml
kubectl -n plain  apply -f samples/sleep/sleep.yaml

kubectl -n mesh-a rollout status deploy/httpbin deploy/sleep --timeout=180s
kubectl -n plain  rollout status deploy/sleep --timeout=180s
```

4. Confirmá la inyección contando contenedores:

```bash
kubectl -n mesh-a get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl -n plain  get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo
```

5. Establecé la línea base: ambos clientes pueden llegar a `httpbin` en este momento.

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a  -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "plain   -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

**Preguntas**

- **Q5.1** ¿Qué label habilitó la inyección del sidecar, y en qué ámbito se aplicó? Nombrá el mecanismo de admisión que actúa sobre él.
- **Q5.2** Nombrá el contenedor sidecar y el init container que observaste. ¿Qué le hace el init container al network namespace del pod?
- **Q5.3** Ambos curls devolvieron `200`. Dado que Istio está instalado, ¿está cifrada en este punto la llamada `mesh-a → httpbin`? Justificá tu respuesta.
- **Q5.4** ¿Por qué aplicar el label de inyección al namespace *después* de crearlo igual funcionó para estos deployments, y qué tendrías que hacer si los pods ya hubieran existido?
- **Q5.5** El cliente `plain` tuvo éxito. ¿Qué configuración por defecto de Istio lo hizo posible?

---

## Ejercicio 6 — Forzar mTLS con PeerAuthentication

**Objetivo:** la tarea central de Istio. Pasar de TLS mutuo oportunista a forzado, y observar exactamente qué se rompe.

1. Inspeccioná la política efectiva antes de cambiar nada:

```bash
kubectl get peerauthentication -A
istioctl x describe pod -n mesh-a $(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
```

2. Aplicá mTLS STRICT con **ámbito de namespace**. El nombre `default` más la ausencia de `selector` es el idiom para todo el namespace:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: mesh-a
spec:
  mtls:
    mode: STRICT
EOF

kubectl -n mesh-a get peerauthentication default -o yaml
```

3. Volvé a ejecutar ambos clientes y anotá la diferencia:

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a  -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -w "plain   -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

4. Demostrá qué identidades están en uso. Extraé el certificado de la carga de trabajo del almacén SDS de Envoy y decodificalo:

```bash
istioctl proxy-config secret deploy/sleep -n mesh-a

istioctl proxy-config secret deploy/sleep -n mesh-a -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep -E 'Issuer|Subject:|Not After|URI:|X509v3 Subject Alternative Name' -A1
```

5. Confirmá que los handshakes están ocurriendo y que nada está fallando:

```bash
POD=$(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

kubectl -n mesh-a exec "$POD" -c istio-proxy -- \
  pilot-agent request GET stats | grep -E 'ssl\.handshake|ssl\.connection_error|ssl\.fail'
```

6. Revisá qué exige ahora el listener de entrada:

```bash
istioctl proxy-config listener "$POD" -n mesh-a --port 15006 -o json \
  | grep -E 'requireClientCertificate|transport_socket|tlsMinimumProtocolVersion' | sort -u | head
```

**Preguntas**

- **Q6.1** ¿Qué código HTTP o error de curl obtuvo el cliente `plain`, y en qué capa fue rechazado — Envoy, iptables o la aplicación?
- **Q6.2** Escribí completa la identidad SPIFFE de la carga de trabajo sleep de `mesh-a`. ¿Qué tres piezas de metadata de Kubernetes codifica?
- **Q6.3** ¿Cuál es el período de validez del certificado, quién lo emite, y qué componente lo rota?
- **Q6.4** Nombrá los otros dos ámbitos a los que puede apuntar un `PeerAuthentication` además de un solo namespace, e indicá qué distingue a cada uno en el manifiesto.
- **Q6.5** `PeerAuthentication` en STRICT protege el tráfico de entrada. ¿Qué recurso gobierna si el *cliente* ofrece un certificado, y cuál es el valor de campo relevante?
- **Q6.6** Compará `PERMISSIVE` y `STRICT`. ¿Por qué una migración a STRICT normalmente pasa primero por PERMISSIVE?

---

## Ejercicio 7 — Excepciones, precedencia y los errores que cuestan puntos

**Objetivo:** la mayoría de los fracasos de examen en este tema son errores de ámbito y precedencia, no de sintaxis.

1. Agregá una política STRICT de alcance mesh en el namespace raíz de Istio, y después observá cómo interactúa con la política de namespace:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF

kubectl get peerauthentication -A
```

2. Ahora recortá una excepción para un puerto legacy. Supongamos que `httpbin` debe aceptar texto plano solo en el puerto de contenedor `80`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: httpbin-legacy-port
  namespace: mesh-a
spec:
  selector:
    matchLabels:
      app: httpbin
  mtls:
    mode: STRICT
  portLevelMtls:
    "80":
      mode: PERMISSIVE
EOF

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "plain -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

3. Introducí una caída autoinfligida clásica — un `DestinationRule` que deshabilita el TLS del lado del cliente contra un servidor STRICT:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin-break
  namespace: mesh-a
spec:
  host: httpbin.mesh-a.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE
EOF

sleep 5
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

4. Diagnosticalo como lo harías en el examen, después eliminalo:

```bash
istioctl analyze -n mesh-a
istioctl x describe pod -n mesh-a $(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

kubectl -n mesh-a delete destinationrule httpbin-break
sleep 5
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

5. Restaurá un estado final limpio y correcto: STRICT en todo el mesh, sin excepciones, sin DestinationRule roto.

```bash
kubectl -n mesh-a delete peerauthentication httpbin-legacy-port
kubectl get peerauthentication -A
kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -w "plain -> %{http_code}\n" http://httpbin.mesh-a:8000/get || echo "rejected (expected)"
```

**Preguntas**

- **Q7.1** Indicá el orden de precedencia de `PeerAuthentication` cuando existen políticas a nivel de carga de trabajo, de namespace y de mesh. ¿Dónde se ubica `portLevelMtls`?
- **Q7.2** En el paso 2 la excepción a nivel de puerto se escribió para `"80"`, pero el cliente llama al servicio en el puerto `8000`. ¿Qué número de puerto hace coincidir `portLevelMtls`, y por qué importa esa distinción?
- **Q7.3** En el paso 3 la petición falló aunque ambos pods tienen sidecars y certificados válidos. Explicá la falla en una frase.
- **Q7.4** ¿Cuál es la división funcional entre `PeerAuthentication` y `DestinationRule` para mTLS? ¿Cuál es del lado del servidor y cuál del lado del cliente?
- **Q7.5** Habilitás STRICT en todo el mesh y un servidor Prometheus fuera del mesh deja de recolectar métricas de aplicación. Nombrá dos formas de resolverlo sin debilitar la política globalmente.
- **Q7.6** Después de habilitar STRICT, ¿por qué las liveness probes HTTP del kubelet suelen seguir funcionando sin que hagas ningún cambio?
- **Q7.7** `PeerAuthentication` en STRICT significa "los llamadores deben presentar un certificado válido del mesh". ¿Qué recurso necesitás además si el requisito es "solo la service account `frontend` puede llamar a `httpbin`"?

---

## Ejercicio 8 — Elegir la capa correcta, y limpieza

**Objetivo:** consolidar. El examen puede darte un requisito y esperar que elijas Cilium, Istio, o ambos.

1. Levantá ambas capas a la vez. Reactivá WireGuard de Cilium mientras Istio STRICT está activo:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i '^Encryption'
```

2. Verificá que el mesh sigue funcionando, y capturá el tráfico doblemente protegido:

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n enc-lab exec sniffer -- timeout 20 tcpdump -ni any -c 10 -A -s0 'udp port 51871'
```

3. Completá esta tabla de decisión con lo que observaste (escribí tus respuestas antes de verificar):

| Requisito | Cilium WireGuard/IPsec | Istio mTLS |
|---|---|---|
| Cifrar tráfico entre pods en nodos **distintos** | ? | ? |
| Cifrar tráfico entre pods en el **mismo** nodo | ? | ? |
| Autenticar la *carga de trabajo llamante* por identidad criptográfica | ? | ? |
| Funciona para protocolos **no-HTTP/agnósticos a TCP** sin cambios en la app | ? | ? |
| Requiere un sidecar o proxy por nodo en el data path | ? | ? |
| Cifrar tráfico de control/host nodo-a-nodo | ? | ? |
| Decisiones de autorización por petición | ? | ? |

4. Desarmá el laboratorio:

```bash
kubectl delete ns enc-lab mesh-a plain --ignore-not-found
kubectl delete peerauthentication default -n istio-system --ignore-not-found
istioctl uninstall --purge -y
kubectl delete ns istio-system --ignore-not-found
kind delete cluster --name enc
```

**Preguntas**

- **Q8.1** Con ambas capas activas, ¿cuántas veces se cifra el payload de `sleep → httpbin` cuando los pods están en nodos distintos? ¿Y en el mismo nodo?
- **Q8.2** ¿Correr ambas capas es desperdicio redundante, o hay una razón defendible? Dá el argumento más fuerte para cada lado.
- **Q8.3** Un requisito dice: "todo el tráfico entre microservicios debe estar cifrado **y** cada servicio debe probar su identidad". ¿Qué capa por sí sola satisface esto, y por qué la otra no?
- **Q8.4** Un requisito dice: "cifrar todo lo que sale de un nodo, incluido el tráfico de cliente del kubelet y de etcd, sin tocar ninguna aplicación". ¿Qué capa, y qué configuración específica?
- **Q8.5** Te piden verificar una afirmación de cifrado pod-a-pod en un clúster que no construiste vos. Enumerá, en orden, las tres comprobaciones que ejecutarías — una para Cilium, una para Istio, una en el cable.

---

## Respuestas

<details>
<summary>Hacé clic para revelar todas las respuestas</summary>

### Ejercicio 1

**A1.1** Sí — `CKS-PLAINTEXT-CANARY` es visible en la salida ASCII de `-A`. El data path por defecto de Cilium **no** cifra el tráfico pod-a-pod. Un plugin CNI te da conectividad y (opcionalmente) política; la confidencialidad es una funcionalidad separada, opcional. Cualquiera con captura de paquetes en el nodo, en un puerto espejado del switch, o en la red subyacente lee tu tráfico entre pods.

**A1.2** UDP puerto **8472** — VXLAN. Ese es el modo de enrutamiento por túnel por defecto de Cilium: el paquete IP interno pod-a-pod se envuelve en una cabecera VXLAN y se envía entre las IPs de los nodos. (Si el clúster usara enrutamiento nativo/directo verías los paquetes de los pods sin encapsular — igualmente en texto plano.)

**A1.3** La encapsulación solo cambia el envoltorio de *direccionamiento* para que los paquetes puedan enrutarse por la red subyacente; los bytes del payload original se transportan textualmente y cualquier observador puede quitar la cabecera externa y leerlos. El cifrado cambia los *bytes*.

**A1.4** El cifrado transparente de Cilium opera sobre el tráfico que sale del nodo. Dos pods en el mismo nodo se comunican enteramente dentro del data path local del kernel y nunca se entregan al dispositivo WireGuard o IPsec. Una prueba en el mismo nodo habría mostrado texto plano incluso con el cifrado correctamente habilitado, llevándote a concluir — erróneamente — que la configuración falló.

**A1.5** El network namespace propio del pod solo muestra el `eth0` de ese pod. Las interfaces que importan — la NIC física, `cilium_vxlan`, y más adelante `cilium_wg0` — viven en el network namespace del **host**. `hostNetwork: true` pone al sniffer ahí; `privileged`/`NET_ADMIN`+`NET_RAW` después permiten la captura en modo promiscuo. En un clúster endurecido esta spec de pod es exactamente lo que un Pod Security Standard en `baseline`/`restricted` está pensado para bloquear — notá que necesitaste una vía de escape con privilegios para ejecutarlo.

### Ejercicio 2

**A2.1** Interfaz `cilium_wg0`; puerto UDP **51871**.

**A2.2** **2** peers. WireGuard construye una malla completa de peers *remotos*, así que cada agente lista todos los nodos menos a sí mismo: 3 nodos → 2 peers cada uno. Si ves menos, el agente de algún nodo no convergió o el puerto de WireGuard está bloqueado entre nodos.

**A2.3** Solo se cifra el tráfico pod-a-pod (y pod-a-endpoint-de-nodo-remoto). El tráfico originado en el **network namespace del host** — kubelet, pods con host-network, daemons a nivel de nodo, tráfico de cliente del plano de control — queda en claro. `--set encryption.nodeEncryption=true` extiende WireGuard a ese tráfico a nivel de host.

**A2.4** `helm upgrade` sin `--reuse-values` restablece los valores no especificados a los defaults del chart, así que `kubeProxyReplacement=true`, `k8sServiceHost` y `k8sServicePort` se perderían. En este clúster kind (construido con `kubeProxyMode: none`) eso elimina el enrutamiento de servicios por completo y el clúster pierde la conectividad de servicios internos. O pasás `--reuse-values` o volvés a suministrar el conjunto completo de valores / un archivo de values. Un archivo de values versionado en git es el hábito más seguro en producción.

**A2.5** Transparente para (1) la **aplicación** — sin cambios de librería, configuración TLS, certificados ni código; y (2) los **objetos de la API de Kubernetes** — sin cambios en Deployments, Services ni specs de pod. El cifrado se negocia entre los agentes de Cilium por debajo de la carga de trabajo.

### Ejercicio 3

**A3.1** No, la cadena del canario desapareció. El tráfico entre nodos ahora aparece como **UDP al puerto 51871** con un payload cifrado opaco. Los paquetes VXLAN en 8472 dejan de verse como tales, porque ahora viajan dentro del túnel WireGuard.

**A3.2** `cilium_wg0` es el lado *previo al cifrado* del túnel — los paquetes se entregan al dispositivo en claro y se cifran en el camino de salida hacia la NIC física. Ver texto plano ahí es exactamente cómo se ve un túnel funcionando correctamente. Esto también es una herramienta útil de diagnóstico: texto plano en `cilium_wg0` más texto cifrado en la NIC confirma el camino completo.

**A3.3** Ningún paquete en `cilium_wg0`. El tráfico pod-a-pod en el mismo nodo lo conmuta el data path eBPF dentro del kernel y nunca cruza la frontera de cifrado. La frontera es el **nodo**, no el pod. Implicancia de seguridad: si tu modelo de amenaza incluye un nodo comprometido o un pod hostil colocado en el mismo nodo, el cifrado en la frontera del nodo no te sirve de nada — necesitás mTLS a nivel de carga de trabajo.

**A3.4** Con precisión: Cilium WireGuard cifra el tráfico pod-a-pod **entre nodos distintos**. El tráfico de pods en el mismo nodo no está cifrado, y el tráfico host-network no está cifrado salvo que además se habilite `nodeEncryption`. Tampoco autentica la *carga de trabajo* par — solo el *nodo* par.

**A3.5** El **modo estricto** de WireGuard (`encryption.strictMode.*`, con un CIDR de pods y flags relacionados; la nomenclatura varía según la versión de Cilium — consultá la documentación de tu release). Descarta el tráfico sin cifrar dentro del CIDR configurado en lugar de permitir que caiga en texto plano, cerrando la ventana durante rollouts o configuraciones parciales. El riesgo es exactamente ese: cualquier nodo o endpoint que no haya convergido, o cualquier flujo legítimo dentro del CIDR que no pueda cifrarse, es **descartado** — convierte una brecha de confidencialidad en una caída de disponibilidad. Desplegalo solo después de confirmar la convergencia completa de los agentes.

### Ejercicio 4

**A4.1**
- `3` — el **ID de clave** (identificador relacionado con el SPI que Cilium usa para seleccionar la clave).
- `rfc4106(gcm(aes))` — la **suite de cifrado**: cifrado autenticado AES-GCM según lo especificado para ESP en el RFC 4106.
- `<hex>` — el **material de clave**, 20 bytes aleatorios codificados en hexadecimal (clave de 16 bytes + salt de 4 bytes para AES-128-GCM).
- `128` — el **ICV / longitud de clave en bits** para el algoritmo.

**A4.2** **1 a 15** (4 bits). Cuando llegás a 15, la siguiente rotación vuelve a 1. No podés usar 0.

**A4.3** El ID de clave es lo que permite que la clave vieja y la nueva coexistan durante el despliegue. Los agentes toman el nuevo secret en momentos ligeramente distintos; con un ID nuevo, un nodo que todavía usa la clave vieja puede ser descifrado por el par del nuevo ID de clave porque ambas SAs existen brevemente. Si reutilizaras el ID, los nodos instalarían una clave distinta bajo el mismo identificador y el tráfico en vuelo fallaría al descifrarse — verías un pico en `XfrmInNoStates`/errores de descifrado y conexiones caídas.

**A4.4** Protocolo IP **50 (ESP)** — `tcpdump` muestra `ESP(spi=0x...,seq=...)` y ningún payload legible. No hay puerto UDP de túnel salvo que entre en juego el NAT traversal (encapsulación UDP).

**A4.5** Ventaja de WireGuard: mucho más simple operativamente — no hay un secret de clave precompartida que crear, distribuir o rotar; las claves se generan por nodo y se intercambian automáticamente, y hay mucho menos estado que depurar. IPsec puede ser obligatorio donde un régimen de cumplimiento exige una implementación de cifrado validada por FIPS o un protocolo aprobado por estándar, o donde el equipamiento/política de red existente está construido alrededor de ESP.

**A4.6** Ninguno autentica la **identidad de la carga de trabajo** del par. Ambos autentican *nodos*: cualquier pod en un nodo confiable puede hablar con cualquier pod en otro nodo confiable, y el lado receptor no puede determinar criptográficamente qué servicio lo llamó. El mTLS de Istio ata un certificado a una ServiceAccount, que es lo que hace posible la autorización basada en identidad.

### Ejercicio 5

**A5.1** `istio-injection=enabled` en el **namespace**. Actúa sobre él un **MutatingAdmissionWebhook** (`istio-sidecar-injector`) que reescribe las specs de pod en el momento de la creación. Las instalaciones basadas en revisiones usan `istio.io/rev=<revision>` en su lugar, y una anotación/label por pod (`sidecar.istio.io/inject`) puede sobrescribir la configuración del namespace.

**A5.2** Contenedor sidecar: **`istio-proxy`** (Envoy más `pilot-agent`). Init container: **`istio-init`** (o el plugin `istio-cni` cuando se instala el modo CNI). Programa reglas de iptables/nftables en el network namespace del pod que redirigen todo el tráfico de entrada a Envoy en el puerto **15006** y todo el tráfico de salida al puerto **15001**, de modo que el proxy queda inevitablemente en el camino.

**A5.3** Casi con certeza **sí** — pero no *forzado*. El modo por defecto de `PeerAuthentication` en Istio es `PERMISSIVE`, y el mTLS automático de Istio hace que el proxy del lado del cliente prefiera mTLS cuando el destino tiene un sidecar. Así que el salto sidecar-a-sidecar está cifrado oportunistamente. El problema de seguridad es que no es *obligatorio*: un llamador en texto plano es aceptado igualmente, así que un atacante simplemente se niega a usar TLS. Un cifrado que es opcional no es un control.

**A5.4** La inyección ocurre en la **creación del pod**, y los Deployments crearon sus pods después de que se aplicó el label. Si los pods ya hubieran existido, no llevarían sidecar; hay que reiniciarlos — `kubectl -n mesh-a rollout restart deploy/<name>` — para que el webhook vuelva a mutar los pods nuevos.

**A5.5** El modo mTLS `PERMISSIVE` — el default. El proxy del lado del servidor acepta tanto mTLS como texto plano en el mismo puerto, lo que existe para permitir una migración incremental al mesh sin una caída.

### Ejercicio 6

**A6.1** curl falla con un error de transporte, típicamente `curl: (56) Recv failure: Connection reset by peer` y un `%{http_code}` de `000`. El rechazo ocurre en **Envoy** en el pod servidor: el listener de entrada en 15006 ahora exige un certificado de cliente, y la conexión en texto plano se resetea durante el handshake TLS. No es una respuesta de la aplicación ni un drop de iptables — la conexión TCP se acepta y luego se derriba, que es la razón por la que obtenés un reset en lugar de un timeout o un `403`.

**A6.2** `spiffe://cluster.local/ns/mesh-a/sa/sleep`. Codifica el **trust domain** (`cluster.local`), el **namespace** (`mesh-a`) y la **ServiceAccount** (`sleep`). Aparece en el Subject Alternative Name del certificado como un URI SAN — el Subject DN en sí está vacío, lo que sorprende a quienes leen estos certificados por primera vez.

**A6.3** La validez es corta — del orden de **24 horas** por defecto. El emisor es la CA de Istio (`istiod`, mostrada como `CN=cluster.local` o la raíz configurada). `pilot-agent` dentro del sidecar solicita y rota el certificado a través de la API **SDS** (Secret Discovery Service) bastante antes del vencimiento, de modo que nunca se escribe un secret en disco ni se guarda como Secret de Kubernetes. Por eso no hay certificado que rotar manualmente ni material de clave que un atacante pueda robar de etcd.

**A6.4**
- **De alcance mesh**: la política vive en el **namespace raíz de Istio** (`istio-system` por defecto) y **no tiene `selector`**.
- **Específica de carga de trabajo**: vive en el namespace de la carga de trabajo y **tiene un `selector.matchLabels`** que hace coincidir los pods objetivo.

(Una política de alcance de namespace es el caso intermedio: namespace de la carga de trabajo, sin selector. El nombre convencional `default` es una convención de legibilidad, no un requisito funcional, salvo que solo debería existir una política de alcance mesh/namespace por ámbito.)

**A6.5** `DestinationRule`, campo `spec.trafficPolicy.tls.mode: ISTIO_MUTUAL`. En Istio moderno rara vez lo escribís — el mTLS automático se encarga del lado cliente — pero es el recurso que sobrescribe el comportamiento del cliente, y ahí `mode: DISABLE` o `SIMPLE` es una causa frecuente de "STRICT rompió mi mesh".

**A6.6** `PERMISSIVE` acepta tanto mTLS como texto plano en el mismo puerto; `STRICT` acepta **solo** mTLS. La migración pasa por PERMISSIVE porque los sidecars se inyectan pod por pod a lo largo del tiempo: saltar directo a STRICT rompería a todo llamador que todavía no fue inyectado o reiniciado. La secuencia correcta es: inyectar en todas partes → confirmar mediante los contadores `ssl.handshake` y la telemetría que esencialmente todo el tráfico ya es mTLS → recién ahí poner STRICT. PERMISSIVE es un estado de migración, nunca un estado final.

### Ejercicio 7

**A7.1** Gana lo más específico: **nivel de carga de trabajo** (con `selector`) sobrescribe **nivel de namespace**, que sobrescribe **nivel de mesh** (namespace raíz). `portLevelMtls` es aún más específico — sobrescribe el `mtls.mode` de la propia política en la que aparece, solo para los puertos listados. Notá que la sobrescritura *no* es una fusión: la política ganadora reemplaza a la más amplia por completo, así que una política de carga de trabajo que omite una configuración no la hereda de la política de namespace.

**A7.2** `portLevelMtls` hace coincidir el **puerto de la carga de trabajo / del contenedor** que el pod realmente escucha, no el puerto del Service. `httpbin` se expone como puerto de Service `8000` apuntando al puerto de contenedor `80`, así que la excepción escrita para `"80"` es la correcta y la llamada en texto plano tiene éxito. Confundirse esto al revés es una trampa común de examen: leé `targetPort`, no `port`.

**A7.3** Al proxy del cliente se le indicó enviar **texto plano** a un destino cuyo proxy **exige** mTLS, así que el handshake nunca ocurre y la conexión se resetea — un desajuste autoinfligido entre el `DestinationRule` del lado cliente y el `PeerAuthentication` del lado servidor.

**A7.4** `PeerAuthentication` es del **lado servidor**: declara qué tráfico de entrada aceptará una carga de trabajo. `DestinationRule.trafficPolicy.tls` es del **lado cliente**: declara qué enviará el proxy del llamador. Deben coincidir; tanto `istioctl analyze` como `istioctl x describe pod` señalan el conflicto explícitamente.

**A7.5** Dos cualesquiera de:
- Agregar una excepción **`portLevelMtls: PERMISSIVE`** para el puerto de métricas en las cargas de trabajo recolectadas.
- Traer a Prometheus **dentro del mesh** (inyectar su sidecar) para que pueda presentar un certificado.
- Recolectar a través del **endpoint de métricas fusionadas del sidecar en el puerto 15020**, que está exento de la aplicación de mTLS.

La primera es la de menor radio de impacto; la segunda es la más limpia a largo plazo.

**A7.6** El inyector de sidecars **reescribe las probes HTTP** por defecto (`sidecar.istio.io/rewriteAppHTTPProbe`), apuntando al kubelet hacia el puerto de salud de `pilot-agent` (15021), que después sondea la aplicación localmente. Dado que el kubelet vive en el network namespace del host y no puede hacer mTLS del mesh, sin esta reescritura STRICT haría fallar toda probe HTTP y dejaría la carga de trabajo en CrashLoop. Notá la salvedad: las probes **exec** y las probes en puertos manejados de forma inusual pueden requerir atención igualmente, y si deshabilitás la reescritura de probes tenés que excluir vos mismo el puerto de la probe.

**A7.7** Una **`AuthorizationPolicy`**. `PeerAuthentication` establece *que* el llamador tiene una identidad verificada del mesh; `AuthorizationPolicy` decide *qué* identidades pueden hacer *qué* — p. ej. `rules[].from[].source.principals: ["cluster.local/ns/mesh-a/sa/frontend"]`. Autenticación y autorización son recursos separados, y una tarea de examen que nombra un llamador específico quiere el segundo.

### Ejercicio 8

**A8.1** **Dos veces** entre nodos: el mTLS de Istio cifra el payload sidecar-a-sidecar, y WireGuard de Cilium cifra los paquetes resultantes nodo-a-nodo. Por eso la captura en UDP 51871 es opaca incluso en la capa externa. En el **mismo nodo**: **una vez** — solo aplica la capa de mTLS de Istio, ya que no se cruza la frontera de cifrado de Cilium.

**A8.2** *En contra*: sobrecarga real de CPU y MTU por un segundo envoltorio de datos que ya están cifrados y autenticados, más dos sistemas que depurar cuando algo se rompe. *A favor*: defienden fronteras distintas. El mTLS de Istio cubre solo el tráfico que atraviesa sidecars — deja afuera los pods no incorporados al mesh, el tráfico host-network y cualquier cosa que esquive el proxy; el cifrado de Cilium cubre todo lo que sale del nodo sin importar la pertenencia al mesh, incluido ese residuo. Defensa en profundidad también significa que una mala configuración en una capa (un `DestinationRule: DISABLE` perdido) no expone texto plano en el cable. En entornos regulados esta estratificación suele ser obligatoria.

**A8.3** **El mTLS de Istio**. El cifrado transparente de Cilium autentica *nodos*, no cargas de trabajo — el pod receptor no tiene evidencia criptográfica de qué servicio lo llamó, así que no se pueden cumplir requisitos de identidad por servicio y la autorización basada en identidad es imposible. Istio emite un certificado SPIFFE por ServiceAccount, que satisface ambas mitades del requisito.

**A8.4** **Cilium**, con **`encryption.nodeEncryption=true`** junto a `encryption.enabled=true` y el `encryption.type` elegido. Esto extiende el cifrado al tráfico host-network, que ningún mesh de sidecars puede alcanzar. Verificá con `cilium-dbg status | grep Encryption` — `NodeEncryption` debería decir `Enabled`.

**A8.5** En orden:
1. **Cilium**: `kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i Encryption` — revisar el tipo, `NodeEncryption` y la cantidad de peers en *todos* los agentes, no solo en uno; después `cilium-dbg encrypt status` para los contadores de error.
2. **Istio**: `kubectl get peerauthentication -A` para encontrar todas las políticas y su ámbito, verificando `PERMISSIVE`, `DISABLE` y excepciones de `portLevelMtls`; contrastar con `kubectl get destinationrule -A -o yaml | grep -A3 tls:` para sobrescrituras del lado cliente, y `istioctl x describe pod <pod>` para el veredicto efectivo por carga de trabajo.
3. **En el cable**: capturar desde un pod privilegiado con `hostNetwork` en un nodo y confirmar que un marcador conocido de texto plano **no** aparece en la interfaz física — y acordate de correr la prueba **entre nodos**, porque una prueba en el mismo nodo no prueba nada sobre la capa de Cilium.

La configuración dice qué se pretendía; la captura dice qué es cierto. Hacé ambas.

</details>

---

## Referencias

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Cilium — Transparent Encryption (WireGuard & IPsec) — https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — WireGuard Transparent Encryption — https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium — IPsec Transparent Encryption and key rotation — https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Cilium — Helm reference (`encryption.*`) — https://docs.cilium.io/en/stable/helm-reference/
- Cilium — CLI / `cilium-dbg` troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- WireGuard protocol overview — https://www.wireguard.com/protocol/
- RFC 4106 — The Use of Galois/Counter Mode (GCM) in IPsec ESP — https://www.rfc-editor.org/rfc/rfc4106
- RFC 4303 — IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303
- Istio — Mutual TLS Migration — https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — PeerAuthentication API reference — https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Authentication concepts and policy precedence — https://istio.io/latest/docs/concepts/security/#authentication
- Istio — DestinationRule TLS settings — https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — AuthorizationPolicy reference — https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Sidecar injection — https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — Health checking with mTLS (probe rewrite) — https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/
- Istio — Prometheus scraping with mTLS — https://istio.io/latest/docs/ops/integrations/prometheus/
- SPIFFE ID specification — https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md
- kind — Configuration (`disableDefaultCNI`, `kubeProxyMode`) — https://kind.sigs.k8s.io/docs/user/configuration/