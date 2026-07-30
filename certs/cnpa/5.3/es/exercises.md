# Ejercicios Guiados — 5.3 Kubernetes Networking Model and CNI Plugins

## Ejercicio 1 — Microsegmentación con NetworkPolicy

1. Crear un namespace de laboratorio y aplicar una política default-deny:
   ```bash
   kubectl create namespace net-lab
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-all
     namespace: net-lab
   spec:
     podSelector: {}
     policyTypes:
     - Ingress
     - Egress
   EOF
   ```
2. Verificar que la política se ha aplicado correctamente:
   ```bash
   kubectl get networkpolicy -n net-lab
   ```
3. Intentar conectarse desde un Pod al servicio backend y observar el bloqueo:
   ```bash
   kubectl exec -n net-lab deploy/frontend -- curl -s --connect-timeout 3 http://backend:8080
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. La política `deny-all` bloquea todo tráfico de entrada y salida. Se necesitan políticas adicionales para permitir explícitamente la comunicación deseada.
2. La conexión fallará con timeout porque no existe una regla que permita el tráfico entre frontend y backend.

</details>