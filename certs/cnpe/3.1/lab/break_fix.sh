# 3.1 Configuring Secure Service-to-Service Communication

## Motivación y Arquitectura de Zero Trust Networking

En arquitecturas de microservicios sobre Kubernetes, la seguridad del perímetro (firewalls externos) no es suficiente. El modelo de seguridad de la plataforma debe asumir **Zero Trust** (cero confianza): cada solicitud entre servicios (*East-West traffic*) debe autenticarse criptográficamente, autorizarse y cifrarse en tránsito mediante **mTLS (Mutual TLS)**.

---

## 1. Identidad Criptográfica con SPIFFE/SPIRE

**SPIFFE (Secure Production Identity Framework for Everyone)** define un estándar abierto para emitir identidades criptográficas únicas a cargas de trabajo en formato URI (`SPIFFE ID`): `spiffe://cluster.local/ns/prod/sa/payment-api`.

**SPIRE (SPIFFE Runtime Environment)** es el software de la CNCF que emite y rota automáticamente certificados X.509 (*SVIDs - SPIFFE Verifiable Identity Documents*) de corta duración a los Pods de la plataforma.

---

## 2. Implementación de mTLS con Service Mesh (Istio / Cilium Service Mesh)

### 2.1 Istio PeerAuthentication (mTLS Estricto)

El recurso `PeerAuthentication` fuerza a todos los workloads del namespace a aceptar únicamente conexiones cifradas con mTLS usando identidades SPIFFE.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: platform-prod
spec:
  mtls:
    mode: STRICT
```

### 2.2 Cilium WireGuard / IPsec Cifrado Transparente

Cilium permite activar cifrado de red pod-a-pod transparente a nivel de kernel utilizando **WireGuard** o **IPsec** sin necesidad de inyectar proxies sidecar.

```bash
# Activar cifrado transparente WireGuard en Cilium
helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
```

---

## Verificación de mTLS en Tránsito

```bash
# Capturar paquetes en la interfaz del nodo para verificar que el tráfico viaja cifrado (WireGuard)
$ tcpdump -i cilium_wg0 -n
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- SPIFFE/SPIRE Standard — https://spiffe.io/docs/latest/
- Istio Security Architecture — https://istio.io/latest/docs/concepts/security/