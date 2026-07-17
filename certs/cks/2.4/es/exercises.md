# 2.4 Implement Pod-to-Pod encryption (Cilium, Istio)

> Fuente de referencia: [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

El tráfico entre Pods viaja, por defecto, sin cifrar dentro del clúster: cualquiera con acceso a la red de nodos (o a un nodo comprometido) puede capturarlo con `tcpdump` y leerlo en texto plano. Este dominio cubre dos estrategias complementarias para resolverlo:

- **Cifrado transparente a nivel de red (CNI)**: Cilium puede cifrar todo el tráfico Pod-to-Pod entre nodos usando **WireGuard** (o IPsec, ahora legacy) sin que la aplicación se entere. Opera en L3/L4.
- **mTLS a nivel de service mesh**: Istio inyecta un sidecar (`istio-proxy`) en cada Pod que negocia TLS mutuo con identidades criptográficas por workload, emitidas por `istiod`. Opera en L7 y además da autenticación de identidad, no solo confidencialidad.

Es clave entender que son mecanismos independientes y combinables: Cilium cifra el "tubo" entre nodos, Istio cifra y autentica la conversación entre servicios sin importar en qué nodo corran.

---

## Ejercicio 1: Verificar el CNI y el estado de cifrado actual de Cilium

1. Confirmá que el CNI del clúster es Cilium:

```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

2. Revisá el estado general del agente en un nodo:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --verbose
```

3. Buscá específicamente la línea de cifrado:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --verbose | grep -i encryption
```

Por defecto vas a ver `Encryption: Disabled`.

4. Revisá el ConfigMap que controla la configuración del agente:

```bash
kubectl -n kube-system get cm cilium-config -o yaml | grep -i -E "encrypt|wireguard"
```

**Pregunta 1.1:** ¿Por qué conviene revisar el estado de cifrado *antes* de intentar habilitarlo, en vez de asumir que está apagado?

**Pregunta 1.2:** El cifrado de Cilium actúa a nivel de nodo (túnel entre `cilium_wg0` de cada host). ¿Qué implica esto si dos Pods que se comunican están en el *mismo* nodo?

---

## Ejercicio 2: Habilitar cifrado transparente con WireGuard

En un clúster real de examen no vas a tener acceso a internet para `helm repo add`, así que editamos el ConfigMap directamente.

1. Editá la configuración del agente:

```bash
kubectl -n kube-system edit cm cilium-config
```

2. Agregá (o modificá) la clave:

```yaml
enable-wireguard: "true"
```

3. Reiniciá el DaemonSet para que los agentes releean la config:

```bash
kubectl -n kube-system rollout restart daemonset cilium
kubectl -n kube-system rollout status daemonset cilium
```

4. (Alternativa si el clúster fue instalado con Helm y tenés el repo disponible localmente):

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart daemonset cilium
```

5. Verificá que quedó activo:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --verbose | grep -i encryption
```

Deberías ver algo como `Encryption: Wireguard` con la interfaz `cilium_wg0` listada.

**Pregunta 2.1:** ¿Qué ventaja tiene WireGuard sobre IPsec como backend de cifrado en Cilium (versiones recientes lo recomiendan como default y deprecan IPsec)?

**Pregunta 2.2:** Después de editar el ConfigMap, ¿por qué el `rollout restart` del DaemonSet es un paso obligatorio y no opcional?

---

## Ejercicio 3: Validar que el tráfico node-to-node realmente se cifra

1. Desplegá dos Pods en nodos distintos, forzando el placement:

```bash
kubectl run pod-a --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"<nodo-1>"}}' -- sleep 3600
kubectl run pod-b --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"<nodo-2>"}}' -- sleep 3600
```

2. Confirmá que quedaron en nodos diferentes:

```bash
kubectl get pods -o wide
```

3. Probá conectividad entre ambos:

```bash
IP_B=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
kubectl exec pod-a -- ping -c 2 $IP_B
```

4. Confirmá, desde el propio agente de Cilium, que el tráfico entre esos nodos está pasando por el túnel cifrado (no hay bypass):

```bash
kubectl -n kube-system exec ds/cilium -- cilium encrypt status
```

**Pregunta 3.1:** ¿Qué columna de `kubectl get pods -o wide` usaste para confirmar que los Pods están en nodos distintos, y por qué es necesario ese paso antes de sacar conclusiones sobre el cifrado?

**Pregunta 3.2:** Si `pod-a` y `pod-b` terminan programados en el mismo nodo por el scheduler, ¿el test de este ejercicio sigue siendo válido para demostrar que el cifrado node-to-node funciona? ¿Por qué?

---

## Ejercicio 4: Instalar el sidecar de Istio y habilitar la inyección automática

1. Verificá que Istio está instalado y `istiod` corriendo:

```bash
kubectl get pods -n istio-system
```

2. Etiquetá el namespace de trabajo para inyección automática de sidecar:

```bash
kubectl create namespace mesh-demo
kubectl label namespace mesh-demo istio-injection=enabled
```

3. Desplegá una app de prueba:

```bash
kubectl -n mesh-demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/sleep/sleep.yaml
kubectl -n mesh-demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/httpbin/httpbin.yaml
```

4. Confirmá que cada Pod tiene 2/2 contenedores (app + `istio-proxy`):

```bash
kubectl -n mesh-demo get pods
```

**Pregunta 4.1:** Etiquetaste el namespace `mesh-demo` con `istio-injection=enabled` *después* de que ya existiera un Pod corriendo ahí. ¿Ese Pod preexistente queda con sidecar inyectado automáticamente? ¿Qué acción manual hace falta?

**Pregunta 4.2:** ¿Qué diferencia hay entre este modelo de "sidecar" y el modo "ambient mesh" de Istio en cuanto a dónde vive la lógica de mTLS?

---

## Ejercicio 5: Forzar mTLS con `PeerAuthentication` en modo STRICT

1. Aplicá una política a nivel de namespace que exija mTLS estricto:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: mesh-demo
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f peer-auth-strict.yaml
```

2. Probá tráfico *dentro* de la malla (Pod con sidecar → Pod con sidecar):

```bash
kubectl -n mesh-demo exec deploy/sleep -c sleep -- curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get
```

Debería devolver `200`.

3. Probá tráfico desde *fuera* de la malla (un Pod sin sidecar, en otro namespace):

```bash
kubectl run curl-plain --image=curlimages/curl -- sleep 3600
kubectl exec curl-plain -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://httpbin.mesh-demo:8000/get
```

Esta conexión debería fallar o cerrarse (connection reset), porque `httpbin` ya no acepta texto plano.

**Pregunta 5.1:** ¿Cuál es la diferencia práctica entre `mtls.mode: PERMISSIVE` y `STRICT`, y por qué `PERMISSIVE` suele usarse como paso intermedio en una migración a mTLS?

**Pregunta 5.2:** Si aplicás el `PeerAuthentication` a nivel de `mesh` (namespace `istio-system`, `name: default`) en vez de a nivel de namespace, ¿qué alcance tiene el cambio?

---

## Ejercicio 6: Verificar que el mTLS está activo desde la CLI

1. Describí el estado de mTLS de un Pod específico:

```bash
istioctl x describe pod $(kubectl -n mesh-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}') -n mesh-demo
```

Buscá la sección que indica el modo de TLS efectivo aplicado por la política.

2. Inspeccioná el certificado que el sidecar obtuvo de `istiod`:

```bash
istioctl proxy-config secret deploy/httpbin.mesh-demo -o json | \
  jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
```

3. Confirmá que el SAN del certificado tiene el formato de identidad SPIFFE de Istio (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`).

**Pregunta 6.1:** ¿Qué comando de `istioctl` usarías para confirmar rápidamente el modo mTLS aplicado a un workload, sin tener que parsear certificados a mano?

**Pregunta 6.2:** El certificado del sidecar codifica la identidad como una URI SPIFFE basada en el Service Account del Pod, no en su IP. ¿Qué ventaja de seguridad da esto frente a una autenticación basada en IP de origen?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**1.1** — Porque habilitar cifrado sobre un sistema que ya lo tiene activo puede ser inofensivo, pero diagnosticar "no cifra" cuando en realidad nunca se verificó la línea base te hace perder tiempo y puede llevar a conclusiones erróneas en el examen (¿es que no funciona, o es que nunca se activó?). Siempre se arranca confirmando el estado real antes de cambiar algo.

**1.2** — Si ambos Pods están en el mismo nodo, el tráfico nunca sale por la interfaz física ni pasa por el túnel `cilium_wg0`: se resuelve localmente (loopback/veth dentro del mismo host). El cifrado de Cilium protege tráfico *entre nodos*, no dentro de un mismo nodo, así que ese caso no sirve para validar que el cifrado funciona.

**2.1** — WireGuard usa criptografía moderna (Curve25519, ChaCha20, Poly1305), tiene una implementación mucho más simple y auditable (pocas miles de líneas vs. la complejidad histórica de IPsec/strongSwan), y no requiere gestionar manualmente un Secret con material de claves IPsec ni lidiar con rotación de SPI. Por eso Cilium lo recomienda como default y fue deprecando el soporte de IPsec en versiones recientes.

**2.2** — El agente de Cilium lee su configuración al arrancar; el ConfigMap no se aplica en caliente a un proceso ya corriendo. `rollout restart` fuerza que cada Pod del DaemonSet se recree y vuelva a leer `cilium-config`, propagando `enable-wireguard: "true"` a todos los nodos.

**3.1** — La columna `NODE`. Es necesario porque el cifrado node-to-node de Cilium solo entra en juego cuando el tráfico efectivamente cruza el enlace físico entre dos hosts; si el scheduler puso ambos Pods en el mismo nodo, el test no prueba nada sobre el túnel cifrado.

**3.2** — No, no es válido tal cual. Si ambos terminan en el mismo nodo hay que forzar el placement (como se hizo con `nodeName` en el paso 1) o repetir el test hasta lograr que queden en nodos distintos, porque de lo contrario el tráfico nunca atraviesa la interfaz `cilium_wg0` y el resultado no dice nada sobre si el cifrado funciona.

**4.1** — No. La inyección de sidecar ocurre en el *webhook de admisión* al momento de crear el Pod; etiquetar el namespace no afecta a Pods ya existentes. Hace falta borrar y recrear el Pod (o hacer `kubectl rollout restart` del Deployment que lo maneja) para que el nuevo Pod pase por el webhook con la etiqueta ya presente.

**4.2** — En modo sidecar, cada Pod lleva su propio proxy `istio-proxy` como contenedor adicional, y ahí vive toda la lógica de mTLS, routing y políticas. En modo ambient, esa lógica se saca del Pod y se centraliza en un proxy L4 por nodo (`ztunnel`) más un proxy L7 opcional (`waypoint`) compartido, eliminando la necesidad de inyectar un contenedor extra en cada Pod.

**5.1** — En `PERMISSIVE`, el workload acepta tanto conexiones mTLS como texto plano en el mismo puerto, lo que permite que servicios sin sidecar sigan funcionando durante la migración. En `STRICT`, solo se aceptan conexiones mTLS: cualquier cliente sin sidecar (o sin certificado válido de la malla) es rechazado. `PERMISSIVE` se usa como paso intermedio para no romper servicios que todavía no tienen sidecar inyectado mientras se completa el rollout.

**5.2** — Aplicado a nivel de mesh (namespace `istio-system`, `name: default`), el `PeerAuthentication` se convierte en la política default para *todo el mesh*, salvo que un namespace o workload tenga una política más específica que la sobreescriba (Istio prioriza: workload-specific > namespace-specific > mesh-wide).

**6.1** — `istioctl x describe pod <pod> -n <namespace>` (usado en el paso 1), que resume el modo de TLS efectivo aplicado a ese workload sin necesidad de decodificar certificados manualmente. También existe `istioctl proxy-config` para inspección más detallada del estado del proxy.

**6.2** — La identidad va atada al Service Account (y por lo tanto a permisos RBAC y a quién desplegó el workload), no a una dirección IP que puede reasignarse, spoofearse o compartirse entre Pods según el CNI. Esto da autenticación de identidad real del *workload* que se comunica, en vez de confiar en de dónde "parece" venir el tráfico.

</details>