# Ejercicios Guiados — 5.2 Traffic Management, Canary Releases, and Circuit Breaking

## Ejercicio 1 — Configuración de Canary Release con VirtualService

1. Crear un namespace para laboratorio de tráfico:
   ```bash
   kubectl create namespace traffic-lab
   ```
2. Inspeccionar la división de tráfico del recurso `VirtualService`:
   ```bash
   kubectl get virtualservice -n traffic-lab
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. `VirtualService` define las reglas de ponderación (*weights*) para derivar tráfico a distintas versiones de la aplicación.

</details>