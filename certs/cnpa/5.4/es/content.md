# 5.4 Ingress Controllers, Gateway API, and External Traffic Management

## Motivación y Gestión de Tráfico Norte-Sur

El tráfico externo (**North-South Traffic**) hacia los servicios de Kubernetes se gestiona mediante **Ingress Controllers** (NGINX Ingress, Traefik, Envoy Gateway) y la nueva **Gateway API** (estándar de la CNCF).

---

## 1. Ingress vs Gateway API

| Aspecto | Ingress (v1) | Gateway API (v1) |
|---|---|---|
| **Madurez** | Estable, ampliamente adoptado | GA desde K8s 1.27+ |
| **Modelo de roles** | Monolítico (un solo recurso) | Separación: GatewayClass → Gateway → HTTPRoute |
| **Funcionalidades** | TLS, host/path routing básico | Traffic splitting, header matching, cross-namespace |

---

## 2. Gateway API — Estructura Declarativa

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: gateway-infra
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      certificateRefs:
      - name: platform-tls-cert
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: platform-prod
spec:
  parentRefs:
  - name: platform-gateway
    namespace: gateway-infra
  hostnames:
  - "api.platform.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
    backendRefs:
    - name: platform-api
      port: 8080
```

---

## Verificación de Rutas

```bash
# Inspeccionar las rutas HTTP asociadas al Gateway
$ kubectl get httproutes -A
NAMESPACE        NAME        HOSTNAMES                        AGE
platform-prod    api-route   ["api.platform.example.com"]     5m
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes Gateway API — https://gateway-api.sigs.k8s.io/
- NGINX Ingress Controller — https://kubernetes.github.io/ingress-nginx/