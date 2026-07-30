# Ejercicios Guiados — 3.6 GitOps Basics, Controllers, and Workflows

## Ejercicio 1 — Inspección de Controladores de GitOps en el Clúster

1. Crear un namespace de pruebas para validar la instalación de Argo CD o Flux:
   ```bash
   kubectl create namespace gitops-lab
   ```
2. Verificar el estado de ejecuciones de los pods del plano de control de GitOps:
   ```bash
   kubectl get pods -n argocd
   ```
3. Inspeccionar las aplicaciones declaradas en la Custom Resource Definition `Application`:
   ```bash
   kubectl get applications -n argocd
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Los controladores de GitOps monitorean el repositorio Git y reconcilian cualquier deriva de configuración (*drift*) detectada en el clúster.

</details>