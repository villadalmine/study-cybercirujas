# 4.1 Software Supply Chain Security and SBOM Principles

## Motivación y Seguridad en la Cadena de Suministro

Proteger la cadena de suministro de software (**Software Supply Chain Security**) exige auditorías continuas y la generación de inventarios **Software Bill of Materials (SBOM)** en formatos SPDX o CycloneDX para cada artefacto OCI.

---

## 1. Generación de SBOM con Syft

```bash
syft myregistry.io/app:v1.0 -o spdx-json > sbom.spdx.json
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Anchore Syft — https://github.com/anchore/syft