# 1.4 Platform Architecture and Core Capabilities

> Referencia: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

Una **Arquitectura de Plataforma (Platform Architecture)** moderna se estructura en capas de capacidades para proporcionar computación, almacenamiento, red, gestión de secretos, observabilidad e integración continua como un servicio unificado.

---

## 1. Las Capas Fundamentales de una IDP

```
+-------------------------------------------------------------+
|        Developer Interface (Backstage / CLI / Portal)       |
+-------------------------------------------------------------+
|  Control Plane & Governance (Crossplane / Kyverno / ArgoCD) |
+-------------------------------------------------------------+
|  Core Services (Ingress / Cert-Manager / Vault / Monitoring)|
+-------------------------------------------------------------+
|   Container Orchestration & Runtime (Kubernetes / containerd)|
+-------------------------------------------------------------+
|    Infrastructure Layer (Public Cloud / On-Prem / Baremetal) |
+-------------------------------------------------------------+
```

---

## 2. Capacidades Clave de la Plataforma

- **Infrasctructure Provisioning**: Aprovisionamiento automatizado con IaC.
- **Application Delivery & Lifecycle**: GitOps y estrategias de despliegue progresivo.
- **Security & Identity**: Certificados automatizados (`cert-manager`) y gestión de secretos criptográficos (`External Secrets Operator` / Vault).
- **Observability**: Métricas, logs y trazas listas para usar (*Zero-Configuration Telemetry*).

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Platforms Whitepaper — https://tag-app-delivery.cncf.io/wgs/platform/whitepaper/