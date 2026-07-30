# Ejercicios Guiados — 5.1 Service Mesh Concepts, Sidecars, and Proxy Architectures

## Ejercicio 1 — Inyección de Sidecar de Service Mesh

1. Crear un namespace etiquetado para inyección de sidecar de Istio:
   ```bash
   kubectl create namespace mesh-lab
   kubectl label namespace mesh-lab istio-injection=enabled
   ```
2. Desplegar un Pod y verificar la presencia del contenedor `istio-proxy`:
   ```bash
   kubectl get pods -n mesh-lab
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. El webhook de mutación inyecta el contenedor Envoy en la especificación del Pod durante la admisión.

</details>