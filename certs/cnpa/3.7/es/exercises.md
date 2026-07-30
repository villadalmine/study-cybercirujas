# Ejercicios Guiados — 3.7 GitOps for Multi-Environment Application Management

## Ejercicio 1 — Gestión Multi-Entorno con Kustomize

1. Crear directorios para los entornos de desarrollo y producción:
   ```bash
   mkdir -p overlays/dev overlays/prod
   ```
2. Inspeccionar la renderización de manifiestos con Kustomize:
   ```bash
   kubectl kustomize overlays/dev
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Kustomize permite reutilizar manifiestos base mediante overlays específicos para cada entorno sin duplicación de código.

</details>