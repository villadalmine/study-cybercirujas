# Ejercicios Guiados — 4.4 Cryptographic Identity Management and Secret Storage

## Ejercicio 1 — Sincronización de Secretos con External Secrets Operator

1. Crear un namespace para laboratorio de secretos:
   ```bash
   kubectl create namespace secrets-lab
   ```
2. Inspeccionar la sincronización de objetos `ExternalSecret`:
   ```bash
   kubectl get externalsecrets -n secrets-lab
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. External Secrets Operator sincroniza dinámicamente credenciales desde proveedores externos como HashiCorp Vault.

</details>