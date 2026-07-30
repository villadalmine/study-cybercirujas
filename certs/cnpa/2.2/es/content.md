# 2.2 Secure Service-to-Service Communication

## Motivación y mTLS en la Plataforma

La comunicación segura entre servicios dentro de un clúster de Kubernetes se basa en **mTLS (Mutual TLS)** y la autenticación basada en identidad criptográfica impulsada por proyectos como **SPIFFE/SPIRE** o mallas de servicios (**Istio / Linkerd / Cilium Service Mesh**). En un modelo de seguridad Zero Trust, todo el tráfico pod-a-pod debe cifrarse y validarse mediante certificados X.509 de corta duración.

---

## 1. Identidad Criptográfica con SPIFFE/SPIRE

- **SPIFFE (Secure Production Identity Framework for Everyone)**: Define un estándar para emitir identidades criptográficas únicas (`SPIFFE ID`) en formato URI: `spiffe://cluster.local/ns/prod/sa/backend-api`.
- **SPIRE (SPIFFE Runtime Environment)**: Es el software de implementación de la CNCF que emite y rota automáticamente certificados SVID a los contenedores.

---

## 2. Encriptación en Tránsito con Service Mesh (Istio / Cilium)

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

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- SPIFFE/SPIRE Documentation — https://spiffe.io/docs/latest/spire-about/spire-concepts/
- Istio Mutual TLS Authentication — https://istio.io/latest/docs/concepts/security/#mutual-tls-authentication