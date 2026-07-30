# 4.2 Artifact Signing, Attestations, and Verification

## Motivación y Firma de Artefactos con Cosign

Firma criptográfica de imágenes OCI y atestaciones de seguridad utilizando **Cosign (Sigstore)** para prevenir el despliegue de artefactos no autenticados en producción.

---

## 1. Firma y Verificación de Imágenes

```bash
# Firmar imagen con Cosign
cosign sign --key cosign.key myregistry.io/app:v1.0

# Verificación de firma antes del despliegue
cosign verify --key cosign.pub myregistry.io/app:v1.0
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Sigstore Cosign — https://docs.sigstore.dev/cosign/overview/