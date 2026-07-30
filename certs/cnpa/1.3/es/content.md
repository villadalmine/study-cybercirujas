# 1.3 Application Environments and Infrastructure Architecture

## Motivación y Paridad de Entornos

El diseño de **entornos de aplicación (Application Environments)** e infraestructura debe garantizar la paridad entre desarrollo, staging y producción (*Dev/Prod Parity*), aislamiento multi-tenant y reproducibilidad mediante IaC.

---

## 1. Paridad de Entornos y Entornos Efímeros

- **Dev/Prod Parity**: Minimiza discrepancias entre entornos.
- **Entornos Efímeros (Ephemeral Environments)**: Namespaces temporales o `vclusters` creados por Pull Request para pruebas continuas.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- 12 Factor App: Dev/Prod Parity — https://12factor.net/dev-prod-parity