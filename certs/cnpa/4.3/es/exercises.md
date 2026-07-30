# Ejercicios Guiados — 4.3 Vulnerability Scanning and Continuous Risk Assessment

## Ejercicio 1 — Escaneo de Vulnerabilidades con Trivy

1. Crear un namespace de pruebas:
   ```bash
   kubectl create namespace scan-lab
   ```
2. Ejecutar escaneo estático de vulnerabilidades:
   ```bash
   trivy image --severity CRITICAL nginx:latest
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Trivy identifica los CVEs conocidos presentes en las capas de la imagen.

</details>