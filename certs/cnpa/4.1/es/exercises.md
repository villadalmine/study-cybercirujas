# Ejercicios Guiados — 4.1 Software Supply Chain Security and SBOM Principles

## Ejercicio 1 — Generación de SBOM de una Imagen

1. Crear un namespace para pruebas de seguridad:
   ```bash
   kubectl create namespace sbom-lab
   ```
2. Generar el SBOM de la imagen `nginx:alpine`:
   ```bash
   syft nginx:alpine -o spdx-json > nginx.spdx.json
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Un SBOM provee visibilidad completa sobre los paquetes y bibliotecas incluidas en una imagen de contenedor.

</details>