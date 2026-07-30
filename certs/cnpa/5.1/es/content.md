# 5.1 Service Mesh Concepts, Sidecars, and Proxy Architectures

## Motivación y Arquitectura Service Mesh

**Service Mesh** abstrae la comunicación este-oeste (*East-West Traffic*) en clústeres mediante un plano de control (**Istio / Linkerd**) y proxies de plano de datos (**Envoy** sidecars o eBPF ambient mesh).

---

## 1. Sidecar vs Ambient (eBPF) Mesh

- **Sidecar Pattern (Envoy)**: Proxy inyectado como contenedor secundario en cada Pod.
- **Sidecarless / Ambient Mesh (Cilium / Istio Ambient)**: Proxies por nodo a nivel de L4/L7 operando mediante eBPF.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Istio Architecture — https://istio.io/latest/docs/ops/deployment/architecture/
- Envoy Proxy — https://www.envoyproxy.io/