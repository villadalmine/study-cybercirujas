# 3.3 Generating Audit Trails and Enforcing Policy Compliance (SBOM, Compliance Reports, etc.)

## Motivación y Seguridad en la Cadena de Suministro de Software

Garantizar la integridad de las aplicaciones en producción requiere visibilidad total sobre la **cadena de suministro de software (Software Supply Chain Security)**. Esto implica auditar cada interacción con la API de Kubernetes y generar una **Software Bill of Materials (SBOM)** firmada para cada artefacto desplegado.

---

## 1. Auditoría de Kubernetes (Audit Logging)

El motor de auditoría de Kubernetes registra todas las solicitudes recibidas por el `kube-apiserver`.

```yaml
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

## 2. Generación y Firmado de SBOM (Syft & Cosign)

- **Syft (Anchore)**: Genera la lista completa de componentes y dependencias (SBOM) en formatos SPDX o CycloneDX.
- **Cosign (Sigstore)**: Firma criptográficamente la imagen y adjunta la atestación del SBOM en el OCI Registry.

```bash
# Generar SBOM de una imagen de contenedor
syft myregistry.io/app:v1.0 -o spdx-json > sbom.spdx.json

# Adjuntar y firmar el SBOM en el Registry con Cosign
cosign attach sbom --sbom sbom.spdx.json myregistry.io/app:v1.0
cosign sign --key cosign.key myregistry.io/app:v1.0
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Audit Logging — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Sigstore Cosign & Attestations — https://docs.sigstore.dev/cosign/overview/