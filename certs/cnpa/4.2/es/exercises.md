# Ejercicios Guiados — 4.2 Artifact Signing, Attestations, and Verification

## Ejercicio 1 — Firma y Verificación de Artefactos OCI

1. Crear un namespace para laboratorio de firma:
   ```bash
   kubectl create namespace signing-lab
   ```
2. Verificar una firma pública de Cosign:
   ```bash
   cosign verify --key cosign.pub myregistry.io/app:v1.0
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Cosign garantiza la integridad criptográfica de la imagen y previene manipulaciones no autorizadas en el Registry.

</details>