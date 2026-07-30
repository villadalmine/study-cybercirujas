# 3.1 Configuring Secure Service-to-Service Communication

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

La comunicación segura entre servicios dentro de un clúster de Kubernetes se basa en **mTLS (Mutual TLS)** y autenticación basada en identidad criptográfica impulsada por proyectos como **SPIFFE/SPIRE** o mallas de servicios (**Istio / Linkerd / Cilium Service Mesh**).

---

## 1. Fundamentos de mTLS en Cloud Native

En mTLS, tanto el cliente como el servidor se autentican mutuamente mediante certificados X.509 antes de establecer el túnel cifrado.

### SPIFFE/SPIRE
- **SPIFFE (Secure Production Identity Framework for Everyone)**: Define un estándar para emitir identidades criptográficas únicas (`SPIFFE ID`) en formato URI: `spiffe://cluster.local/ns/prod/sa/backend-api`.
- **SPIRE (SPIFFE Runtime Environment)**: Es el software de implementación de la CNCF que emite y rota automáticamente certificados SVID (SPIFFE Verifiable Identity Document) a los contenedores.

---

## 2. Encriptación en Tránsito con Service Mesh (Istio / Cilium)

### Istio PeerAuthentication (STRICT mTLS)
Fuerza a todos los workloads del namespace a aceptar únicamente conexiones cifradas con mTLS.

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

### Cilium WireGuard / IPsec
Cilium permite activar cifrado de tráfico pod-a-pod a nivel de kernel utilizando **WireGuard** o **IPsec** transparente, sin necesidad de inyectar sidecars en cada Pod.

```bash
# Activar cifrado transparente WireGuard en Cilium
cilium config set enable-wireguard true
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- SPIFFE/SPIRE Documentation — https://spiffe.io/docs/latest/spire-about/spire-concepts/
- Istio Mutual TLS Authentication — https://istio.io/latest/docs/concepts/security/#mutual-tls-authentication
- Cilium Transparent Encryption — https://docs.cilium.io/en/stable/security/encryption/