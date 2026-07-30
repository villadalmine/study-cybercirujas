# 3.3 Generating Audit Trails and Enforcing Policy Compliance (SBOM, Compliance Reports, etc.)

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El cumplimiento normativo y la visibilidad de la cadena de suministro de software (**Software Supply Chain Security**) requieren la generación de listas de materiales de software (**SBOM**), trazabilidad de auditoría (*Audit Logging*) y generación automatizada de informes de compliance.

---

## 1. Kubernetes Audit Logging

El motor de auditoría de Kubernetes registra todas las solicitudes recibidas por el API Server.

```yaml
# Policy de auditoría declarativa
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
- level: RequestResponse
  users: ["system:admin"]
```

---

## 2. Software Bill of Materials (SBOM) y Firmado con Cosign / Syft

- **SBOM (Software Bill of Materials)**: Documento estructurado (formatos SPDX o CycloneDX) que enumera todos los componentes, librerías y dependencias de una imagen de contenedor.
- **Syft**: Herramienta CLI para generar SBOMs.
- **Cosign (Sigstore)**: Firma imágenes de contenedor y adjunta atestaciones de SBOM directamente en el OCI Registry.

```bash
# Generar SBOM de una imagen en formato SPDX
syft myregistry.io/app:v1.0 -o spdx-json > sbom.spdx.json

# Firmar el SBOM y subirlo al OCI Registry con Cosign
cosign attach sbom --sbom sbom.spdx.json myregistry.io/app:v1.0
cosign sign --key cosign.key myregistry.io/app:v1.0
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Audit Logging — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Sigstore Cosign & SBOM Attestations — https://docs.sigstore.dev/cosign/overview/
- Anchore Syft SBOM Generator — https://github.com/anchore/syft