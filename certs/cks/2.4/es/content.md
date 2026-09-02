# 2.4 Implementar cifrado Pod-a-Pod (Cilium, Istio)

## 1. Por qué existe este tema

Una `NetworkPolicy` responde a *"quién tiene permitido hablar con quién"*. No dice nada sobre *"puede un tercero leer lo que dijeron"*. En un clúster Kubernetes por defecto, el tráfico pod-a-pod que cruza el límite de un nodo sale del nodo como paquetes IP en texto plano sobre la red subyacente — la encapsulación VXLAN/Geneve y el enrutamiento nativo **no** son cifrado, son encuadre (framing).

El modelo de amenazas contra el que te estás defendiendo:

| Posición del atacante | Qué obtiene sin cifrado |
|---|---|
| Nodo comprometido (root) | `tcpdump` en la NIC física → todos los flujos que transitan por ese nodo, incluido el tráfico de otros tenants |
| Dispositivo de red comprometido / mirroring de VPC / tap del proveedor cloud | Texto plano completo del tráfico pod-a-pod |
| Atacante que se une a la red subyacente (bare metal, on-prem, L2 compartida) | Sniffing pasivo, spoofing de ARP/rutas, MITM activo |
| Pod comprometido sin NetworkPolicy | Alcanza servicios a los que no debería — mitigado por política, *y* por identidad de workload si usás mTLS |

El cifrado en tránsito te da **confidencialidad**, **integridad** y — según el mecanismo — **autenticación del par**. Esa última es la distinción importante, y es el eje en el que difieren las dos tecnologías del examen.

Una demostración rápida del problema. El nodo `worker-1` ejecuta el cliente, `worker-2` ejecuta el servidor:

```bash
$ kubectl exec -it client -- curl -s -H 'X-Token: CKS-SECRET-PAYLOAD' http://10.0.2.45:80/
```

En `worker-1`, esnifando la interfaz física:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp and host 10.0.2.45' 2>/dev/null | grep -i CKS-SECRET
X-Token: CKS-SECRET-PAYLOAD
```

La cabecera está en el cable en texto claro. Todo lo que sigue trata de hacer que ese `grep` no devuelva nada.

---

## 2. Las tres capas donde podés cifrar

| Capa | Mecanismo | Identidad del par | Esfuerzo | Cubre |
|---|---|---|---|---|
| **L3 / datapath (CNI)** | Cilium WireGuard o IPsec, Calico WireGuard | **Nodo** — un par de claves por nodo | Muy bajo: un flag, sin cambios en la app | *Todo* el tráfico de pods entre nodos, cualquier protocolo (TCP, UDP, SCTP, ICMP) |
| **L4-L7 / service mesh** | Istio mTLS (sidecar o ambient), Linkerd | **Workload** — identidad SPIFFE derivada del ServiceAccount | Medio: instalación del mesh, inyección, política | Tráfico mesh basado en TCP entre workloads inscriptos |
| **Aplicación** | TLS terminado en la app, cert-manager para los certificados | Lo que la app valide | Alto: código + ciclo de vida de certificados | Solo lo que implementes |

Modelo mental clave para el examen:

- **El cifrado a nivel CNI es cifrado masivo transparente.** Protege el cable. Dos pods en el *mismo nodo* confían entre sí implícitamente, y cualquier proceso con acceso a nivel de nodo al datapath ve texto plano. No puede expresar "solo `frontend` puede autenticarse como cliente ante `payments`".
- **El mTLS del mesh es identidad criptográfica de workload.** Cada pod obtiene su propio certificado X.509 de corta duración con un SAN URI SPIFFE, así que podés autorizar según *quién demuestra ser el par* en lugar de según la IP. Solo cubre el tráfico que efectivamente pasa por los proxies.

Son complementarios, no alternativos. Un clúster endurecido suele correr Cilium WireGuard *y* Istio con mTLS STRICT.

---

## 3. Cifrado transparente de Cilium

Cilium ofrece dos modos mutuamente excluyentes: **WireGuard** e **IPsec**. Ambos se habilitan por clúster y ambos cifran el tráfico de pods que sale del nodo.

### 3.1 WireGuard

Moderno, simple, sin material de claves que tengas que gestionar: cada agente genera un par de claves al arrancar, publica la clave pública en su propio CRD `CiliumNode`, y cada otro agente la recoge y construye una entrada de peer. La criptografía es ChaCha20-Poly1305; la interfaz de túnel es `cilium_wg0` en el puerto UDP **51871**.

**Habilitarlo (Helm — el camino documentado):**

```bash
helm upgrade cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

**Habilitarlo (ConfigMap — el camino rápido cuando el clúster del examen ya tiene Cilium y no hay metadatos de release de Helm):**

```bash
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"enable-wireguard":"true"}}'
kubectl -n kube-system rollout restart ds/cilium
```

**Verificar.** Dentro del pod del agente la CLI es `cilium-dbg` (1.16+; se llama `cilium` en imágenes más viejas):

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i encryption
Encryption:  Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: jL8t...9Uk=, Port: 51871, Peers: 2)]
```

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
	Public key: jL8tQ2r6bK1s0mV7oR4pZ3hN5cY8wX2fT6dA1eQ9Uk=
	Number of peers: 2
```

`Number of peers` debe ser `<cantidad de nodos> - 1` en cada agente. Un nodo que falte en la lista de peers es un nodo cuyo tráfico sigue en claro. En el host mismo:

```bash
$ sudo wg show cilium_wg0
interface: cilium_wg0
  public key: jL8tQ2r6bK1s0mV7oR4pZ3hN5cY8wX2fT6dA1eQ9Uk=
  listening port: 51871

peer: 7Hs2...pQ4=
  endpoint: 192.168.1.12:51871
  allowed ips: 10.0.2.0/24, 192.168.1.12/32
  latest handshake: 42 seconds ago
  transfer: 1.21 MiB received, 986.44 KiB sent
```

**Demostralo en el cable.** Volvé a lanzar la petición anterior, luego esnifá:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp and host 10.0.2.45' 2>/dev/null | grep -i CKS-SECRET
# (nada — el flujo ya no es visible como TCP en eth0)

$ sudo tcpdump -ni eth0 -c 4 'udp port 51871'
09:41:02.113442 IP 192.168.1.11.51871 > 192.168.1.12.51871: UDP, length 176
09:41:02.114018 IP 192.168.1.12.51871 > 192.168.1.11.51871: UDP, length 128
```

Podés hacer lo mismo desde dentro del pod del agente cuando no tenés shell en el nodo:

```bash
kubectl -n kube-system exec ds/cilium -- tcpdump -ni any -c 5 'udp port 51871'
```

**Dos opciones de endurecimiento que vale la pena conocer:**

```bash
# Also encrypt host-level (node-to-node) traffic, not just pod traffic
--set encryption.nodeEncryption=true

# Fail closed: drop unencrypted traffic inside the given CIDR instead of
# silently falling back to plaintext
--set encryption.strictMode.enabled=true \
--set encryption.strictMode.cidr=10.0.0.0/16
```

El modo estricto es la respuesta a "el cifrado estaba habilitado pero un nodo mal configurado siguió mandando texto claro y nadie se dio cuenta".

### 3.2 IPsec

Usa el stack XFRM del kernel con ESP. A diferencia de WireGuard, **vos proveés el material de claves** como un Secret, y sos responsable de rotarlo.

**Crear el Secret de la clave.** El formato es `<key-id> <cipher-suite> <hex-key> <key-length>`:

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"
```

```bash
$ kubectl -n kube-system get secret cilium-ipsec-keys \
    -o jsonpath='{.data.keys}' | base64 -d
3 rfc4106(gcm(aes)) 5f2c9a7e13b48d06fa5c8e21b7409dd3ac61e5f8 128
```

**Habilitarlo:**

```bash
helm upgrade cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=ipsec \
  --set encryption.ipsec.secretName=cilium-ipsec-keys \
  --set encryption.ipsec.keyFile=keys \
  --set encryption.ipsec.interface=eth0

kubectl -n kube-system rollout restart ds/cilium
```

**Verificar:**

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 1
Max Seq. Number: 0x2f1/0xffffffff
Errors: 0
```

```bash
$ sudo ip xfrm state | head -6
src 192.168.1.11 dst 192.168.1.12
	proto esp spi 0x00000003 reqid 1 mode tunnel
	replay-window 0
	aead rfc4106(gcm(aes)) 0x5f2c...e5f8 128
	anti-replay context: seq 0x0, oseq 0x2f1, bitmap 0x00000000
	sel src 0.0.0.0/0 dst 0.0.0.0/0
```

```bash
$ sudo tcpdump -ni eth0 -c 3 'esp'
09:52:44.007731 IP 192.168.1.11 > 192.168.1.12: ESP(spi=0x00000003,seq=0x2f2), length 200
```

Tres señales a revisar: `Keys in use: 1` (un valor >1 significa que hay una rotación en curso sin terminar), `Errors: 0`, y `Max Seq. Number` lejos del techo `0xffffffff`.

**Rotación de claves** — incrementá el key ID y parcheá el Secret; los agentes lo recogen y negocian el nuevo SPI:

```bash
NEW_ID=4
NEW_KEY="$NEW_ID rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system patch secret cilium-ipsec-keys \
  -p "{\"stringData\":{\"keys\":\"$NEW_KEY\"}}"

# Wait until every agent reports a single key again before rotating next time
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status | grep 'Keys in use'
```

### 3.3 Cómo elegir entre ellos

| | WireGuard | IPsec |
|---|---|---|
| Gestión de claves | Automática, por nodo, en CRDs `CiliumNode` | Secret manual, rotación manual |
| Cifrador | ChaCha20-Poly1305 | AES-GCM / AES-CBC+HMAC (hay suites compatibles con FIPS) |
| Requisito del kernel | Soporte WireGuard (5.6+ o módulo) | XFRM/ESP, ampliamente disponible |
| Observabilidad | `wg show`, lista de peers | `ip xfrm state/policy`, contadores ESP |
| Elección típica | Recomendación por defecto | Requisito regulatorio de una suite de cifrado específica, u offload de ESP en la NIC |

### 3.4 Limitaciones que tenés que saber enunciar

- **El tráfico pod-a-pod dentro del mismo nodo no se cifra.** Nunca toca el cable; se conmuta en el kernel.
- **Los pods con host-network y el tráfico a nivel de nodo** (kubelet → apiserver, peers de etcd) quedan fuera del datapath de pods salvo que pongas `nodeEncryption=true` — e incluso entonces, el tráfico del plano de control tiene su propio TLS.
- **La identidad es el nodo, no el workload.** Cualquier proceso root en un nodo puede leer todos los flujos que ese nodo maneja. Por eso el cifrado del CNI no reemplaza a mTLS para autorización zero-trust.
- **Caídas de MTU.** WireGuard agrega ~60 bytes de overhead para IPv4; Cilium baja el MTU del pod automáticamente, pero MTUs hardcodeados o tráfico jumbo con `DF` seteado en las aplicaciones pueden empezar a fallar después de habilitarlo.
- Cambiar el modo de cifrado requiere reiniciar el agente, lo que interrumpe brevemente la programación del datapath.

---

## 4. Istio mTLS

### 4.1 Cómo funciona la identidad

1. `istiod` corre una CA interna. Su certificado raíz se distribuye a cada namespace como el ConfigMap `istio-ca-root-cert`.
2. Cada proxy genera una clave, envía una CSR a `istiod` usando el token de su ServiceAccount, y recibe un certificado hoja X.509 de corta duración (por defecto ~24 h, rotado automáticamente al ~50% de su vida útil) entregado por **SDS** — la clave privada nunca sale del pod.
3. La identidad del certificado vive en el SAN como un URI SPIFFE:

```
spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>
```

Esa cadena es la unidad de autorización. Por eso importa "correr cada workload bajo su propio ServiceAccount": con un SA default compartido, todos los workloads de un namespace son criptográficamente indistinguibles.

### 4.2 Modo sidecar: instalar e inscribir

```bash
istioctl install --set profile=default -y
kubectl -n istio-system get pods
```

```
NAME                      READY   STATUS    RESTARTS   AGE
istiod-7c9f5b8d64-2xkqr   1/1     Running   0          58s
```

Inscribí un namespace y reiniciá los workloads (la inyección ocurre en la creación del pod):

```bash
kubectl label namespace app istio-injection=enabled
kubectl -n app rollout restart deploy
kubectl -n app get pod
```

```
NAME                        READY   STATUS    RESTARTS   AGE
frontend-6d8f9c7b54-lm2zp   2/2     Running   0          21s
backend-5b7c4d9f8a-qr7tn    2/2     Running   0          19s
```

`2/2` es la señal: contenedor de la app + `istio-proxy`. Un pod `1/1` en un namespace etiquetado fue creado antes de la etiqueta y **no** está en el mesh — será la razón por la que tu política STRICT "no funciona". Las instalaciones basadas en revisión usan `istio.io/rev=<revision>` en lugar de `istio-injection=enabled`.

### 4.3 PeerAuthentication — encender mTLS y volverlo obligatorio

De fábrica, los sidecars inyectados ya usan mTLS *cuando ambos extremos tienen un proxy*, pero el lado receptor queda en modo **PERMISSIVE**: acepta tanto mTLS como texto plano. Permissive es una ayuda para migrar, no un estado final — un atacante simplemente habla en texto plano.

**STRICT a nivel de todo el mesh** (el namespace debe ser el namespace raíz de Istio, el nombre debe ser `default`):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

**Alcance de namespace:**

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: app
spec:
  mtls:
    mode: STRICT
```

**Alcance de workload con una excepción por puerto** — el patrón realista cuando un puerto legacy debe quedar abierto (notá que las claves de `portLevelMtls` son puertos del *workload*, y este bloque solo aplica cuando hay un `selector` presente):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: legacy-metrics
  namespace: app
spec:
  selector:
    matchLabels:
      app: backend
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:
      mode: PERMISSIVE
```

Modos: `STRICT` (mTLS obligatorio), `PERMISSIVE` (se aceptan ambos), `DISABLE` (sin mTLS), `UNSET` (hereda del alcance más amplio). La precedencia es **workload > namespace > mesh**.

**Lado cliente.** `PeerAuthentication` gobierna lo que un servidor *acepta*. Para forzar a los clientes a originar mTLS, usá un `DestinationRule`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: default
  namespace: istio-system
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Istio moderno autodetecta y usa mTLS por defecto para destinos del mesh, así que esto se necesita mayormente para sobrescribir un `DestinationRule` más específico que haya puesto `tls.mode: DISABLE`. Acordate de que un `DestinationRule` explícito con `DISABLE` más un servidor en `STRICT` es una caída autoinfligida clásica.

### 4.4 Verificación

**Política efectiva por pod:**

```bash
$ istioctl x describe pod frontend-6d8f9c7b54-lm2zp -n app
Pod: frontend-6d8f9c7b54-lm2zp
   Pod Revision: default
   Pod Ports: 8080 (frontend), 15090 (istio-proxy)
--------------------
Service: frontend
   Port: http 8080/HTTP targets pod port 8080
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied DestinationRule: default (istio-system)
```

**El certificado que realmente se está usando:**

```bash
$ istioctl proxy-config secret deploy/frontend -n app
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER   NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           1a2b3c4d5e      2026-07-31T09:14:22Z     2026-07-30T09:12:22Z
ROOTCA            CA             ACTIVE     true           4d5e6f7a8b      2036-07-27T08:00:00Z     2026-07-28T08:00:00Z
```

**Extraer la identidad SPIFFE** — esta es la comprobación que demuestra *de quién* es la identidad que tiene el proxy:

```bash
$ istioctl proxy-config secret deploy/frontend -n app -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/app/sa/frontend
```

**Prueba negativa — la única prueba que realmente demuestra STRICT.** Corré un cliente sin sidecar (un namespace sin la etiqueta de inyección) y pegale al servicio directamente:

```bash
$ kubectl -n outside run probe --rm -it --image=curlimages/curl --restart=Never -- \
    curl -sS -m 5 http://backend.app.svc.cluster.local:8080/
curl: (56) Recv failure: Connection reset by peer
pod "probe" deleted
pod default/probe terminated (Error)
```

El reset viene del sidecar del destino rechazando un handshake sin TLS. Desde un cliente inyectado la misma llamada tiene éxito. Si la llamada en texto plano *tiene éxito*, seguís en PERMISSIVE, el pod destino no tiene sidecar, o tu política aterrizó en el namespace equivocado.

**En el cable**, el HTTP en texto plano se convierte en un flujo de registros TLS:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp port 8080' 2>/dev/null | head -4
E..4..@.@....... .....  ....................
.......&.....!...*.spiffe://cluster.local/ns/app/sa/frontend
```

(Es posible que todavía veas el URI SPIFFE en el ClientHello / intercambio de certificados — las identidades son públicas, los payloads no.)

**Contadores** que confirman que el tráfico va por el camino cifrado:

```bash
$ kubectl -n app exec deploy/backend -c istio-proxy -- \
    pilot-agent request GET stats | grep -E 'ssl.handshake|ssl.connection_error'
listener.0.0.0.0_8080.ssl.handshake: 412
listener.0.0.0.0_8080.ssl.connection_error: 0
```

### 4.5 Modo ambient (sin sidecar)

El data plane ambient de Istio reemplaza los sidecars por pod con un DaemonSet **ztunnel** por nodo. El tráfico pod-a-pod se tuneliza sobre **HBONE** — HTTP/2 CONNECT dentro de mTLS en el puerto **15008** — así que obtenés mTLS y autorización L4 sin inyección de sidecars y sin reiniciar pods. Las funcionalidades L7 requieren un proxy **waypoint** adicional.

```bash
istioctl install --set profile=ambient -y
kubectl label namespace app istio.io/dataplane-mode=ambient
kubectl -n istio-system get ds ztunnel
```

```
NAME      DESIRED   CURRENT   READY   AGE
ztunnel   3         3         3       74s
```

Fijate en las diferencias que hacen tropezar a la gente: los pods se quedan en `1/1` (sin contenedor extra), la inscripción tiene efecto sin reinicio, y mTLS está activo por defecto para los workloads inscriptos en ambient. `PeerAuthentication` con `STRICT` sigue aplicando y sigue siendo lo que escribís para volverlo obligatorio. La verificación usa `istioctl ztunnel-config workload` en lugar de `proxy-config`:

```bash
$ istioctl ztunnel-config workload --namespace app
NAMESPACE  POD NAME                    ADDRESS    NODE      WAYPOINT  PROTOCOL
app        frontend-6d8f9c7b54-lm2zp   10.0.1.17  worker-1  None      HBONE
app        backend-5b7c4d9f8a-qr7tn    10.0.2.45  worker-2  None      HBONE
```

`PROTOCOL: HBONE` significa que el workload está inscripto y su tráfico está cifrado con mTLS; `TCP` significa que no.

### 4.6 mTLS es autenticación — agregá autorización

El mTLS STRICT demuestra *quién* es el llamante. No restringe *qué* puede llamar: todo workload del mesh sigue teniendo un certificado válido. Combinalo con una `AuthorizationPolicy` basada en el principal SPIFFE:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backend-allow-frontend
  namespace: app
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/app/sa/frontend"]
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
```

Una línea base de `deny-all` en el namespace, y después permisos explícitos, es el patrón que se corresponde con la mentalidad de "minimizar vulnerabilidades de microservicios":

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: app
spec:
  {}          # no rules + no action → ALLOW nothing
```

Dos notas de precisión: los `principals` se comparan **sin** el prefijo `spiffe://`, y las reglas basadas en principal solo funcionan cuando mTLS está realmente en vigor — bajo PERMISSIVE, un llamante en texto plano no tiene principal y una regla así nunca coincide, en silencio.

### 4.7 Trampas comunes de Istio

- **Los pods creados antes de la etiqueta de inyección** no tienen sidecar; `READY 1/1` es la pista. Reiniciá el Deployment.
- **`PeerAuthentication` en el namespace equivocado.** La política de todo el mesh *debe* llamarse `default` en el namespace raíz (`istio-system` por defecto). Una política que parece de todo el mesh pero está en `app` solo cubre `app`.
- **Las anotaciones de exclusión anulan el cifrado.** `traffic.sidecar.istio.io/excludeInboundPorts` y `excludeOutboundPorts` enrutan el tráfico esquivando el proxy por completo — auditalas; son una puerta trasera de aspecto plausible.
- **Los pods con `hostNetwork: true`** y el tráfico que evita el Service (IP de pod cruda hacia un workload para el que el proxy no tiene listener) pueden escaparse del mesh.
- **Los health probes** son reescritos por Istio automáticamente; si la reescritura de probes está deshabilitada, el probe en texto plano del kubelet será rechazado bajo STRICT.
- **El tráfico que sale del mesh** (bases de datos externas, namespaces fuera del mesh) no está cubierto por `ISTIO_MUTUAL`; usá origination TLS `SIMPLE`/`MUTUAL` en un `DestinationRule` en su lugar.
- Los sidecars solo manejan protocolos **basados en TCP**. El tráfico UDP — incluido DNS — no lo cifra el sidecar; un mecanismo a nivel de CNI sí.

---

## 5. Combinando los mecanismos

Defensa en profundidad para el tráfico pod-a-pod:

1. **Cifrado a nivel CNI (Cilium WireGuard)** — protección general de todo lo que va por el cable, incluido UDP/DNS y namespaces fuera del mesh, con modo estricto para que falle cerrado.
2. **mTLS STRICT de Istio** — identidad criptográfica por workload, de modo que un pod comprometido no pueda suplantar a otro workload.
3. **NetworkPolicy / CiliumNetworkPolicy** — alcanzabilidad con denegación por defecto, de modo que un atacante ni siquiera pueda abrir la conexión.
4. **AuthorizationPolicy** — mínimo privilegio por encima de la identidad.

Se apilan limpiamente, con una salvedad operativa: cuando hay un mesh presente, todo el tráfico de pods fluye por los sidecars, así que tus políticas L3/L4 deben permitir los puertos del proxy (15001/15006/15008/15021) y el acceso de los pods a `istiod` en 15012. Cifrar dos veces cuesta CPU; eso es una decisión de rendimiento, no un problema de corrección.

---

## 6. Referencia rápida de troubleshooting

| Síntoma | Causa probable | Comprobación |
|---|---|---|
| `cilium-dbg encrypt status` muestra `Encryption: Disabled` | El agente se reinició sin la nueva configuración, o la clave del ConfigMap está mal | `kubectl -n kube-system get cm cilium-config -o yaml \| grep -E 'wireguard\|ipsec'` |
| `Number of peers` menor que nodos−1 | Un agente no está sano o su `CiliumNode` no tiene clave pública | `kubectl get ciliumnodes -o yaml \| grep -i wireguard` |
| IPsec `Keys in use: 2` durante mucho tiempo | Rotación trabada; un nodo nunca recibió la nueva clave | `cilium-dbg encrypt status` en cada agente |
| El tráfico sigue en texto plano en tcpdump | Ambos pods están en el **mismo nodo** | `kubectl get pod -o wide` — comparar `NODE` |
| Fallos intermitentes después de habilitar el cifrado | MTU | Probar con `ping -M do -s 1400`, revisar `ip link show cilium_wg0` |
| La política STRICT no tiene efecto | El pod destino no tiene sidecar / la política está en el namespace equivocado | `kubectl get pod` (¿`2/2`?), `kubectl get peerauthentication -A` |
| `upstream connect error ... reset before headers` | El cliente manda texto plano o el `DestinationRule` pone `tls.mode: DISABLE` contra un servidor STRICT | `istioctl x describe pod <pod>` |
| 503 solo para un puerto | `portLevelMtls` usa el puerto del Service en lugar del puerto del workload | Comparar `targetPort` con la clave de `portLevelMtls` |

---

## 7. Runbook de examen

Secuencia rápida y de alto valor cuando una tarea dice "cifrá el tráfico pod-a-pod":

```bash
# --- Which mechanism is already present? ---
kubectl -n kube-system get pods | grep -E 'cilium|calico'
kubectl get ns istio-system && kubectl -n istio-system get pods

# --- Cilium WireGuard, minimum keystrokes ---
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"enable-wireguard":"true"}}'
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status

# --- Istio STRICT mesh-wide ---
kubectl apply -f - <<'EOF'
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

Cosas que tenés que poder responder en una oración cada una:

- Por qué VXLAN no es cifrado.
- Por qué el tráfico dentro del mismo nodo queda en claro bajo el cifrado del CNI.
- Por qué PERMISSIVE no es una postura de seguridad.
- Por qué los ServiceAccounts por workload son un prerrequisito para una autorización mTLS significativa.
- La diferencia entre lo que hacen cumplir `PeerAuthentication` y `AuthorizationPolicy`.

Terminá siempre con una **prueba negativa** (un cliente en texto plano que debe fallar, o un `tcpdump` que no debe mostrar texto claro). Una configuración que fue aplicada no es lo mismo que una configuración que está en vigor.

---

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Cilium — Transparent Encryption: https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — WireGuard Transparent Encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium — IPsec Transparent Encryption and key rotation: https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Cilium — `cilium-dbg` CLI reference: https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Istio — Mutual TLS Migration: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — Peer Authentication (concepts): https://istio.io/latest/docs/concepts/security/#peer-authentication
- Istio — `PeerAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — `AuthorizationPolicy` API reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Certificate management and identity: https://istio.io/latest/docs/concepts/security/#istio-identity
- Istio — Ambient mode overview: https://istio.io/latest/docs/ambient/overview/
- Istio — Ambient mTLS and HBONE: https://istio.io/latest/docs/ambient/architecture/data-plane/
- Istio — `istioctl` reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Kubernetes — Network Policies (what they do and do not cover): https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Securing a Cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- SPIFFE — ID format specification: https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md
- WireGuard — Protocol overview: https://www.wireguard.com/protocol/