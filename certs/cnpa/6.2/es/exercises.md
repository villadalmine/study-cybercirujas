# Ejercicios Guiados — 6.2 Autoscaling Strategies: HPA, VPA, KEDA, and Cluster Autoscaler

## Ejercicio 1 — Configuración de HPA con Custom Metrics

1. Inspeccionar el estado actual del HPA en el clúster:
   ```bash
   kubectl get hpa -A
   ```
2. Describir un HPA y verificar los targets de métricas y el estado de escalamiento:
   ```bash
   kubectl describe hpa platform-api-hpa -n platform-prod
   ```
3. Generar carga para provocar un scale-up y observar la reacción del HPA:
   ```bash
   kubectl run -i --tty load-gen --rm --image=busybox -- /bin/sh -c "while true; do wget -q -O- http://platform-api:8080; done"
   ```

## Ejercicio 2 — Observación de KEDA ScaledObject

1. Listar los objetos escalados de KEDA:
   ```bash
   kubectl get scaledobjects -A
   ```
2. Verificar la cantidad de mensajes pendientes en la cola y la decisión de escalamiento:
   ```bash
   kubectl describe scaledobject queue-worker-scaler -n platform-prod
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. El HPA ajusta el número de réplicas según el porcentaje de utilización de CPU (target 70%) y las métricas custom (http_requests_per_second).
2. El `stabilizationWindowSeconds` previene el flapping (escalamiento y reducción rápida alternada) esperando 5 minutos antes de reducir.
3. KEDA escala a 0 réplicas cuando la cola está vacía (scale-to-zero), eliminando el costo de Pods idle.

</details>