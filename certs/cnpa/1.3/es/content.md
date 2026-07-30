# 1.3 Application Environments and Infrastructure Architecture

> Referencia: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

El diseño de **entornos de aplicación (Application Environments)** e infraestructura debe garantizar paridad entre desarrollo, staging y producción (*Dev/Prod Parity*), aislamiento multi-tenant y reproducibilidad mediante infraestructura como código (IaC).

---

## 1. Paridad entre Entornos y Abstracción

El principio de paridad de entornos asegura que los comportamientos de la aplicación sean idénticos en todos los niveles del ciclo de vida.

- **Entornos Efímeros (Ephemeral / Preview Environments)**: Creación dinámica de namespaces o vclusters temporales por cada Pull Request para pruebas integradas.
- **Parametrización con Helm / Kustomize**: Separación limpia entre manifiestos base y valores específicos de cada entorno.

---

## 2. Estrategias de Aislamiento de Entornos

1. **Aislamiento por Namespace**: Entornos dentro del mismo clúster separados por cuotas (`ResourceQuota`), red (`NetworkPolicy`) y seguridad (`PodSecurityAdmission`).
2. **Aislamiento Virtual (vcluster)**: Clústeres de Kubernetes virtuales ejecutándose comoPods dentro de un clúster host.
3. **Aislamiento por Clúster Físico**: Clústeres dedicados por entorno (ej. clúster de dev vs clúster de prod).

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- 12 Factor App: Dev/Prod Parity — https://12factor.net/dev-prod-parity
- Loft vcluster Virtual Kubernetes — https://www.vcluster.com/