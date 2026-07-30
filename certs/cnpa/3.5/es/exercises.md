# Ejercicios Guiados — 3.5 CI/CD Relationship Fundamentals and Integration

## Ejercicio 1 — Integración CI/CD

1. Crear un namespace de laboratorio:
   ```bash
   kubectl create namespace cicd-lab
   ```
2. Inspeccionar el estado de los controladores:
   ```bash
   kubectl get pods -n cicd-lab
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. CI compila y valida artefactos; CD sincroniza el estado deseado en el clúster.

</details>