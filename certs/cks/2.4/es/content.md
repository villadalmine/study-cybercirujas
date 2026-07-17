# 2.4 Implement Pod-to-Pod Encryption (Cilium, Istio)

## Por qué cifrar el tráfico pod-to-pod

Por defecto, el tráfico entre Pods en Kubernetes viaja en texto plano sobre la red del clúster. Cualquier actor con acceso a la red (nodo comprometido, sniffing en la capa de infraestructura, un `tcpdump` corriendo en un nodo con privilegios) puede capturar tráfico East-West entre servicios. Esto es un problema de **defense in depth**: aunque el clúster esté "adentro" de un perímetro de red confiable, ese perímetro puede romperse (nodo comprometido, cloud provider mal configurado, multi-tenancy).

Cifrar pod-to-pod resuelve **confidencialidad e integridad en tránsito**, no autenticación de identidad a nivel de aplicación (eso lo da mTLS con certificados por identidad, que es justamente lo que agrega Istio/Cilium con SPIFFE-like identities).

Hay dos formas principales de resolver esto en el CKS:

1. **Cifrado transparente a nivel de red (CNI)**: Cilium con IPsec o WireGuard. Cifra en la capa 3/4, transparente a la aplicación, sin cambios en el Pod.
2. **mTLS a nivel de service mesh (L7)**: Istio (o Cilium con su propio mTLS de Service Mesh). Agrega identidad criptográfica por workload (certificados x.509 de corta duración) y cifra el tráfico entre sidecars/proxies.

---

## Opción 1: Cilium — cifrado transparente de red

Cilium puede cifrar **todo** el tráfico pod-to-pod (y node-to-node) sin que las aplicaciones lo sepan, usando **IPsec** o **WireGuard** como backend de cifrado. Esto ocurre a nivel del datapath de eBPF/CNI, así que no requiere sidecars ni cambios en los manifiestos de las apps.

### 1.1 WireGuard (recomendado, más simple)

WireGuard es la opción más simple de operar: usa claves de nodo que Cilium rota automáticamente, sin necesidad de gestionar un keystore de IPsec.

Habilitar WireGuard en una instalación de Cilium vía Helm:

```bash
helm upgrade cilium cilium/cilium --version 1.16.0 \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

Verificar que el cifrado está activo:

```bash
$ cilium status | grep Encryption
Encryption:              Wireguard   [cilium_wg0]
```

Ver el estado del túnel WireGuard entre nodos:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium encrypt status
Encryption: Wireguard
Interface: cilium_wg0
  Public key: 8Wxu...ABC=
  Number of peers: 2
```

Consideraciones de examen:
- Requiere kernel >= 5.10 en los nodos (o el módulo WireGuard cargado).
- No cifra automáticamente el tráfico hacia servicios fuera del clúster.
- Por defecto **no** cifra tráfico hacia/desde `host network` a menos que se configure explícitamente.

### 1.2 IPsec

IPsec es la alternativa cuando el kernel no soporta WireGuard o se requiere compatibilidad con hardware específico. Usa un secreto compartido (PSK) almacenado como `Secret` de Kubernetes.

Crear el secreto de cifrado IPsec:

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3 rfc4106(gcm(aes)) $(openssl rand -hex 20) 128"
```

Habilitar IPsec en Cilium:

```bash
helm upgrade cilium cilium/cilium --version 1.16.0 \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=ipsec \
  --set encryption.ipsec.keyFile=keys \
  --set encryption.ipsec.mountPath=/etc/ipsec \
  --set encryption.ipsec.secretName=cilium-ipsec-keys
```

Verificar el estado de las asociaciones de seguridad (SA) de IPsec:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 1
Max Seq. Number: 0x3f6/0xffffffff
Errors: 0
```

Ambos requieren reiniciar los pods de Cilium (rolling restart del `DaemonSet`) para que el cifrado quede activo en todo el clúster:

```bash
kubectl rollout restart daemonset/cilium -n kube-system
```

### 1.3 Verificación end-to-end del cifrado

Un ejercicio típico de examen es demostrar que el tráfico **realmente** va cifrado, capturando paquetes en la interfaz del nodo:

```bash
# Sin cifrado: se ve el payload HTTP en texto plano
tcpdump -i eth0 -A 'host <pod-ip-destino>'

# Con IPsec/WireGuard activo: solo se ve tráfico ESP (IPsec)
# o UDP encapsulado en cilium_wg0 (WireGuard), payload ilegible
tcpdump -i eth0 esp        # IPsec
tcpdump -i cilium_wg0      # WireGuard
```

---

## Opción 2: Istio — mTLS a nivel de Service Mesh

Istio inyecta un **sidecar Envoy** en cada Pod (vía `istio-proxy`). Todo el tráfico entra y sale del contenedor de aplicación a través de ese proxy. `istiod` actúa como CA interna y emite certificados x.509 de corta duración a cada workload (identidad SPIFFE: `spiffe://cluster.local/ns/<namespace>/sa/<service-account>`). Los sidecars usan esos certificados para negociar **mTLS** automáticamente entre ellos.

### 2.1 Habilitar mTLS estricto a nivel de mesh

El recurso `PeerAuthentication` controla si el mTLS es obligatorio, opcional o deshabilitado.

```yaml
# mtls-strict-mesh.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f mtls-strict-mesh.yaml
```

Modos disponibles:

| Modo | Comportamiento |
|---|---|
| `STRICT` | Solo acepta tráfico mTLS. Rechaza texto plano. |
| `PERMISSIVE` | Acepta mTLS y texto plano (default en instalaciones nuevas, útil para migración). |
| `DISABLE` | Sin mTLS. |

### 2.2 mTLS por namespace o por workload

Para exigir mTLS solo en un namespace específico (más granular que el mesh completo):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: payments
spec:
  mtls:
    mode: STRICT
```

Para un workload puntual (override por `selector`), útil cuando un solo Pod aún no tiene sidecar:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: legacy-app-permissive
  namespace: payments
spec:
  selector:
    matchLabels:
      app: legacy-app
  mtls:
    mode: PERMISSIVE
```

### 2.3 DestinationRule: el lado cliente

`PeerAuthentication` controla qué acepta el servidor. Para forzar que los *clientes* del mesh siempre inicien mTLS, se usa `DestinationRule` con `ISTIO_MUTUAL`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: default-mtls
  namespace: istio-system
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

> En instalaciones recientes de Istio, `istiod` genera esto automáticamente al habilitar mTLS strict, pero para el examen conviene saber crearlo manualmente.

### 2.4 Verificación

Confirmar que el sidecar está inyectado:

```bash
$ kubectl get pod frontend-6d8f9-xyz -o jsonpath='{.spec.containers[*].name}'
frontend istio-proxy
```

Confirmar el estado de mTLS entre dos workloads con `istioctl`:

```bash
$ istioctl x describe pod frontend-6d8f9-xyz
...
Pilot reports that pod frontend belongs to the following workloads:
    Effective PeerAuthentication:
       Workload mTLS mode: STRICT
```

Verificar la configuración TLS efectiva aplicada al proxy:

```bash
$ istioctl proxy-config all frontend-6d8f9-xyz --port 8080 --type cluster -o json | grep -A5 tlsContext
```

Probar que la conexión sin certificado es rechazada (desde un Pod sin sidecar, o con `curl` directo evitando el proxy):

```bash
$ kubectl exec plain-pod -- curl -s -o /dev/null -w "%{http_code}" http://backend.payments.svc.cluster.local
000   # conexión rechazada / reset, confirma que STRICT bloquea texto plano
```

### 2.5 Namespace injection

El mTLS de Istio depende de que el sidecar esté inyectado. Habilitar auto-injection en un namespace:

```bash
kubectl label namespace payments istio-injection=enabled
```

Un Pod creado *antes* de este label no tiene sidecar y debe reiniciarse (`kubectl rollout restart deployment/<nombre>`) para que el webhook de inyección actúe.

---

## Cilium vs Istio: cuándo se usa cada uno

| | Cilium (IPsec/WireGuard) | Istio (mTLS) |
|---|---|---|
| Capa | L3/L4 (red) | L7 (aplicación, vía sidecar) |
| Identidad | Basada en nodo/clave, no por workload | Certificado x.509 por Service Account (SPIFFE) |
| Overhead | Bajo (eBPF/kernel) | Mayor (proxy Envoy por Pod, hop extra) |
| Cambios requeridos | Ninguno en la app | Inyección de sidecar, posible impacto en latencia |
| Autorización fina (L7) | No (Cilium Network Policy es L3/L4, o L7 vía su propio proxy) | Sí (`AuthorizationPolicy` sobre identidad) |
| Caso de uso típico | Cifrar todo el tráfico del clúster sin tocar apps | Zero-trust entre microservicios con identidad fuerte |

En el examen, la pregunta suele ser puntual: "habilitá cifrado transparente con Cilium" (WireGuard/IPsec) **o** "configurá mTLS strict en el namespace X con Istio". Rara vez piden combinarlos. Es clave no confundir **cifrado de transporte** (ambos lo dan) con **autenticación de identidad de servicio** (solo el mesh la da mediante certificados por Service Account).

---

## Errores comunes a evitar en el examen

- Olvidar el `rollout restart` del `cilium` DaemonSet después de habilitar cifrado: los pods de Cilium ya corriendo no toman la config nueva hasta reiniciar.
- Aplicar `PeerAuthentication` en el namespace equivocado: uno en `istio-system` con `name: default` afecta a todo el mesh; uno en un namespace de app solo afecta a ese namespace.
- Suponer que `PERMISSIVE` "ya es seguro": permite texto plano, es un paso de migración, no el estado final esperado en examen si piden "enforce mTLS".
- No verificar la inyección del sidecar (`istio-proxy`) antes de asumir que el mTLS está activo — sin sidecar, no hay mTLS posible sin importar el `PeerAuthentication`.

---

## Referencias

- Cilium Curriculum oficial CKS: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Cilium — Transparent Encryption (WireGuard): https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium — Transparent Encryption (IPsec): https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Istio — Mutual TLS Migration: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — PeerAuthentication reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — DestinationRule reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Security overview (identidad, CA, SPIFFE): https://istio.io/latest/docs/concepts/security/