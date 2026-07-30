# 1.4 Platform Architecture and Core Capabilities

## Motivación y Capas de Plataforma

La **Arquitectura de Plataforma (Platform Architecture)** estructura las capacidades fundamentales (cómputo, red, almacenamiento, seguridad, observabilidad) en capas consumibles por los desarrolladores.

---

## 1. Capas Fundamentales

- **Developer Interface**: Backstage / CLI / Portal.
- **Control Plane & Governance**: Crossplane / Kyverno / ArgoCD.
- **Core Services**: Ingress / Cert-Manager / Vault / Monitoring.
- **Container Orchestration**: Kubernetes / containerd.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Platforms Whitepaper — https://tag-app-delivery.cncf.io/wgs/platform/whitepaper/